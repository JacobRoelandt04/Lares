pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "../../common/power"
import "../../common/power/PowerFloor.js" as Floor

// =============================================================================
// HoldFollower.qml -- what a profile owner does when a module HOLDS a profile on PowerBus
// (modules/common/power): switch to it, remember the profile it left, put that profile back on
// a plain release, and put NOTHING back when the user's hand took the profile away. SiliconService
// and SiliconMock each own one, so the rule is one implementation.
//
//   current            the profile the host is at, or heading to ("quiet" | "balanced" | "performance")
//   ready              the host can switch now; a hold that arrives while it cannot (no helper yet) is
//                      taken up the moment it can
//   switchRequested(name)   switch to `name` -- NOT a manual change: it must not drop the hold it serves
//
// A PowerBus.dropAll (a manual profile change: the popup's, or one made outside it) forgets what was
// held: the release that follows is not a "put it back".
//
// A FLOOR (PowerBus.hold(..., "floor"); the loaded language model's Balanced) raises and never lowers: PowerFloor.js
// says when there is something to raise (Quiet; a Balanced tweaked to lower power, read from the host's `cpu` and `config`;
// never Performance). Where there is none the floor holds nothing -- no pair is captured, nothing is switched -- and where
// a pair is already held (a hard hold took the machine up and let it go) the floor is judged against the profile left, so
// a machine that was at Performance is not brought DOWN to Balanced when the update that raised it ends.
//
// THE PROFILE TO PUT BACK IS KEPT ON DISK. The hold of a system update outlives any one shell: a restarted
// shell finds the run still going and SystemUpdateHold holds Performance again, and a follower that captured
// "the profile it left" from `current` would get, on a fresh shell, whatever the host's model says before it has
// been built from the helper (an empty profile reads as index 1, balanced), or Performance itself, the profile
// the previous shell had already switched to. The release would then restore THAT (the update would end on
// balanced instead of quiet). So the pair {from, applied} is written beside the host's own state file whenever
// it changes (`hold-restore.json`; the host's statePath, when the host persists -- a mock has neither and keeps
// it in memory), read back
// at start, and a restored `from` is never captured over. Cleared with the restore and with a manual
// change. A record found at start with NO hold on the bus -- the run ended while no shell was running -- is
// settled after `graceMs` (the hold of a run that is still going arrives within a moment of the start, and
// a restore in the middle of the update would be the opposite of the point): the plain release rule,
// which puts `from` back only while the host is still at `applied` -- a record from before a reboot, or
// one the user has since changed their mind about, restores nothing.
// =============================================================================
Item {
    id: root

    property string current: ""
    property bool ready: false
    // Where the pair is kept ("" = nowhere): beside the host's state file when the host persists (the service
    // does: `persist` and `statePath`; the mock has neither). The host is read as a `var`, so a host without
    // them is not a type error; a host that wants another place sets `statePath` itself.
    readonly property var _host: root.parent
    property string statePath: (root._host && root._host.persist === true && typeof root._host.statePath === "string"
                                && root._host.statePath !== "") ? root._host.statePath.replace(/[^\/]*$/, "") + "hold-restore.json" : ""
    // How long a record with no hold on the bus waits for the hold of a run that is still going.
    property int graceMs: 8000

    signal switchRequested(string name)

    function follow() {
        let want = PowerBus.heldProfile;
        if (!root.ready) {
            root._pending = true;
            return;
        }
        root._pending = false;
        let lowered = false;
        if (want !== "" && PowerBus.heldIsFloor) {
            lowered = root._from === "" && root._loweredNow();
            if (!Floor.needsRaising(root._from !== "" ? root._from : root.current, want, lowered))
                want = "";
        }
        if (want !== "") {
            // Never capture over a pair that is already held (restored from disk, or taken at the first hold),
            // and never capture a profile the host does not know yet.
            if (root._from === "" && root.current !== "")
                root._from = root.current;
            root._applied = want;
            root._save();
            if (want !== root.current || lowered)
                root.switchRequested(want);
        } else if (root._from !== "") {
            // A plain release: back to what was left, unless somebody changed it since.
            const back = root._from;
            const applied = root._applied;
            root._from = "";
            root._applied = "";
            root._save();
            if (applied !== "" && root.current === applied && back !== root.current)
                root.switchRequested(back);
        }
    }

    // While a hold has raised the profile: what comes back when it ends is `name` now. False when nothing is held.
    function rebase(name) {
        if (root._from === "")
            return false;
        root._from = name;
        root._save();
        return true;
    }

    // ---- Private ---------------------------------------------------------------
    // The host's Balanced is tuned to lower power than the profile itself applies (PowerFloor.belowStock). The host is read
    // as a `var`: one without a `cpu` / `config` (a stand-in) is never lowered.
    function _loweredNow() {
        const h = root._host;
        if (!h || !h.cpu || !h.config || !h.config.profiles || h.cpu.profile !== root.current)
            return false;
        return Floor.belowStock(h.cpu, h.config.profiles[h.cpu.profile]);
    }

    property string _from: ""
    property string _applied: ""
    // this follower switched the profile for the hold it serves (a floor that found the machine high enough switched nothing)
    readonly property bool raised: root._applied !== ""
    property bool _pending: false

    onReadyChanged: {
        if (!root.ready)
            return;
        if (root._pending)
            root.follow();
        else if (root._from !== "" && PowerBus.heldProfile === "")
            graceTimer.restart();      // a record from before this shell, and nothing holding: the run may be over
    }
    Timer {
        id: graceTimer
        interval: root.graceMs
        onTriggered: {
            if (root.ready && PowerBus.heldProfile === "")
                root.follow();
        }
    }

    // ---- the pair on disk ---------------------------------------------------------------------------
    function _validProfile(v) {
        return v === "quiet" || v === "balanced" || v === "performance";
    }
    function _save() {
        if (root.statePath === "")
            return;
        store.setText(root._from === "" ? "{}\n" : JSON.stringify({ from: root._from, applied: root._applied }) + "\n");
    }
    function _load() {
        if (root.statePath === "")
            return;
        store.reload();
        try {
            const o = JSON.parse(store.text() || "{}");
            if (o && root._validProfile(o.from)) {
                root._from = o.from;
                root._applied = root._validProfile(o.applied) ? o.applied : "";
            }
        } catch (e) {}
        // A host that is ready before this runs (its `ready` was true at creation) never fires onReadyChanged
        // with a record to look at.
        if (root._from !== "" && root.ready && PowerBus.heldProfile === "")
            graceTimer.restart();
    }
    FileView {
        id: store
        path: root.statePath
        blockAllReads: true
        blockWrites: true
        printErrors: false
    }
    Component.onCompleted: root._load()

    Connections {
        target: PowerBus
        function onDropped(sources) {
            root._from = "";
            root._applied = "";
            root._save();
        }
        function onChanged() {
            root.follow();
        }
    }
}
