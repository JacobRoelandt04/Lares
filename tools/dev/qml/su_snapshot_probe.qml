pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io

import "modules/common/theme"
import "modules/bar/system_update"
import "modules/bar/system_update/components"

// =============================================================================
// su_snapshot_probe.qml -- the snapshot hook and the undo run in the system update popup (docs/contracts/snapshots.md sections 7, 10, 11).
//
// The REAL PackageUpdateParser, SystemUpdateRunProgress and SystemUpdatePopup, fed the transcripts of pacman's pre-transaction hook
// block as the hook (tools/snapshot/root/hook) prints them, through a stand-in backend that only emits the signals the parser listens to
// (no process, no PTY, no machine). A stand-in SnapshotService answers `ready`, `rows` and the rule (`wantsFor`: 40 packages or a critical name).
//
//   S1 done        a large update: the notch is there from resolve and never moves again, the ball goes
//                  download -> snapshot -> install, the title / line / figure say it, the whole-run figure never goes back
//   S2 small       10 packages, no notch; the hook's `skip small` settles the state and adds nothing
//   S3 run         a notch and the hook answers `skip run`: the ball passes it, the notch stays
//   S4 failed      `failed space`: ONE error (snapshot), pacman's vaguer "failed to run transaction hooks" adds none, the card says
//                  "No snapshot, so nothing was installed" with the reason and the two buttons; "Update without it" is heard
//   S5 two txns    a mixed run: the AUR transaction's `skip run` does not take the first transaction's done snapshot back
//   S6 outside     the hook's lines outside the pre-transaction hooks are not read
//   S7 undo        a pacman -U run: its own titles, no sync / download notches, rows that are not AUR, the notch by the rule
//   S8 line        the idle companion line: words, "No snapshot yet", nothing without a service, constant height
//   S12 real       the captures of real pacman runs in a VM (tools/system_update/fixtures): done, skip, failed, two undos, one pacman refuses, one the plan refuses
//   S9 null        no service: no notch, no line, even while a hook speaks
// Run by tools/dev/su_snapshot_probe.sh; bare it quits at once (no SSP_RUN). `SSP ok|FAIL <id>: what`, then `SSP DONE PASS|FAIL`.
// SSP_GRAB=<dir> also saves the popup at the interesting moments (quiet and normal).
// =============================================================================
ShellRoot {
    id: probe
    settings.watchFiles: false
    readonly property bool run: Quickshell.env("SSP_RUN") === "1"
    readonly property string grabDir: Quickshell.env("SSP_GRAB") || ""
    property int checks: 0
    property int fails: 0
    function check(id: string, ok: bool, what: string): void {
        probe.checks++;
        if (!ok)
            probe.fails++;
        console.log("SSP " + (ok ? "ok  " : "FAIL ") + id + ": " + what);
    }
    Timer { interval: 0; running: !probe.run; onTriggered: Qt.quit() }

    // ---- the stand-in backend: what the parser and the popup read of a TerminalBackend ----
    Item {
        id: be
        property bool running: false
        property bool awaitingInput: false
        property bool passwordPrompt: false
        property string lastPrompt: ""
        property bool attached: false
        property int attachPid: 0
        property var linesModel: ListModel {}
        property color defaultFg: "#5D5D5F"
        property string fontFamily: "Consolas"
        property int trimmedLines: 0
        function submit(text: string): void {}
        signal lineAppended(string raw)
        signal progressPreview(string text)
        signal previewUpdated(string text)
        signal screenRows(var rows)
        signal started()
        signal exited(int code, int status)
    }
    PackageUpdateParser { id: pp; backend: be }

    // ---- the stand-in SnapshotService ----
    QtObject {
        id: snaps
        property bool ready: true
        property var rows: [{ short: "6a493314", timeMs: Date.now() - 180 * 60000, title: "Before 112 packages: linux, mesa",
                              reason: "update", changed: [], notable: ["linux", "mesa"], count: 112, state: "done", keep: false,
                              addedBytes: 1, offsite: false, unfinished: false }]
        function wantsFor(names: var): var {
            return { want: names.length >= 40 || names.indexOf("linux") >= 0, count: names.length, critical: [] };
        }
    }
    property bool serviceOn: true
    SystemUpdateRunProgress {
        id: prog
        parser: pp
        running: be.running
        snapshots: probe.serviceOn ? snaps : null
    }

    property int endCount: 0
    // the service's own end-of-run path, not live (no process, no machine)
    SystemUpdateService {
        id: svc
        live: false
        autoStart: false
        mockAvailable: true
        refreshAfterRun: true
    }
    property int refreshes: 0
    Connections { target: svc.avail; function onRefreshStarted() { probe.refreshes++; } }
    Window {
        id: win
        visible: probe.run
        width: 760
        height: 700
        color: Theme.surface
        SystemUpdatePopup {
            id: popup
            anchors.fill: parent
            backend: be
            parser: pp
            snapshots: probe.serviceOn ? snaps : null
            railParticles: false
            stepsSettleMs: 40
            idleSubtextDelayMs: 40
            verbosityMode: "normal"
            onStartWithoutSnapshotRequested: probe.endCount++
        }
    }

    // ---- the transcripts ----
    // a large update names linux and mesa first (the hook's critical names); a small one is plain
    function nameOf(n: int, i: int): string { return n >= 40 ? (i === 1 ? "linux" : i === 2 ? "mesa" : "pkg" + i) : "pkg" + i; }
    function pkgRows(n: int, aur: int): var {
        const out = [":: " + (n + aur) + " packages to upgrade/install."];
        for (let i = 1; i <= n; i++)
            out.push("  " + i + " extra/" + probe.nameOf(n, i) + " 1.0-1 -> 1.1-1");
        for (let j = 1; j <= aur; j++)
            out.push("  " + (n + j) + " aur/aurpkg" + j + " 1.0-1 -> 1.1-1");
        return out;
    }
    function table(n: int): var {
        const out = ["Package (" + n + ")  Old Version  New Version  Net Change  Download Size"];
        for (let i = 1; i <= n; i++)
            out.push("extra/" + probe.nameOf(n, i) + "  1.0-1  1.1-1  0.10 MiB  1.00 MiB");
        out.push("Total Download Size:  " + n + ".00 MiB");
        return out;
    }
    // everything up to the download, then pacman's integrity checks and the start of the pre-transaction hooks
    function headPre(n: int, aur: int): var {
        return [":: Synchronizing package databases...", ":: Searching AUR for updates..."]
            .concat(probe.pkgRows(n, aur))
            .concat([":: Starting full system upgrade...", "resolving dependencies...", "looking for conflicting packages..."])
            .concat(probe.table(n))
            .concat([":: Retrieving packages..."]);
    }
    readonly property var headInt: [
        "(1/5) checking keys in keyring                       [######] 100%",
        "(2/5) checking package integrity                     [######] 100%",
        "(5/5) checking available disk space                  [######] 100%",
        ":: Running pre-transaction hooks...",
        "(1/2) Taking a system snapshot..."]
    function head(n: int, aur: int): var { return probe.headPre(n, aur).concat(probe.headInt); }
    function installLines(n: int): var {
        const out = [":: Processing package changes..."];
        for (let i = 1; i <= n; i++)
            out.push("(" + i + "/" + n + ") upgrading pkg" + i + "                         [######] 100%");
        return out.concat([":: Running post-transaction hooks...", "(1/2) Arming ConditionNeedsUpdate...", "(2/2) Updating the desktop file MIME type cache..."]);
    }
    readonly property var hookDone: ["lares-snapshot: start 112 packages: linux, mesa, nvidia-open", "lares-snapshot: progress 35",
                                      "lares-snapshot: progress 70", "lares-snapshot: done 6a493314 added=812345678 seconds=24",
                                      "(2/2) Remove old stuff..."]

    function feed(lines: var): void { for (const l of lines) be.lineAppended(l); }
    function begin(kind: string): void {
        pp.runKind = kind;
        be.running = true;
        be.started();
    }
    function end(code: int): void {
        be.running = false;
        be.exited(code, 0);
    }

    // the real captures (su_snapshot_probe.sh makes the lines)
    FileView {
        id: fixtureFile
        path: Quickshell.env("SSP_FIX") || ""
        blockLoading: true
        printErrors: false
    }
    readonly property var real: {
        try { return JSON.parse(fixtureFile.text()); } catch (e) { return ({}); }
    }
    function realLines(name: string): var { const f = probe.real[name]; return f ? f.lines : []; }

    // ---- the sequencer ----
    property var steps: []
    property int stepAt: 0
    property real stepStarted: 0
    function next(): bool { probe.stepAt++; probe.stepStarted = Date.now(); return true; }
    Timer {
        id: driver
        interval: 25
        repeat: true
        onTriggered: {
            if (probe.stepAt >= probe.steps.length) {
                driver.stop();
                console.log("SSP DONE " + (probe.fails === 0 && probe.checks > 0 ? "PASS" : "FAIL") + " (" + (probe.checks - probe.fails) + "/" + probe.checks + ")");
                Qt.quit();
                return;
            }
            const waited = Date.now() - probe.stepStarted;
            let r = true;
            try {
                r = probe.steps[probe.stepAt](waited);
            } catch (e) {
                probe.check("step" + probe.stepAt, false, "threw: " + e);
            }
            if (r === "wait")
                return;
            probe.stepAt++;
            probe.stepStarted = Date.now();
        }
    }
    // `act` once, then wait until `cond` (or `ms` of live time is gone: the check then names `what`)
    function after(act: var, ms: int): var {
        let done = false;
        return w => {
            if (!done) { done = true; act(); return "wait"; }
            return w < ms ? "wait" : true;
        };
    }
    function grab(name: string): var {
        let asked = false, got = false;
        return w => {
            if (probe.grabDir === "") return true;
            if (!asked) {
                asked = true;
                win.contentItem.grabToImage(r => { r.saveToFile(probe.grabDir + "/" + name + ".png"); got = true; });
                return "wait";
            }
            return got || w > 4000 ? true : "wait";
        };
    }
    function mode(m: string): var { return () => { popup.verbosityMode = m; return true; }; }

    // ---- recording of the rail while a run is fed ----
    property var rec: ({ keys: [], steps: [], percent: [], keyChanges: 0, keyChangesAfterSync: 0 })
    function startRec(): void { probe.rec = { keys: [], steps: [], percent: [], keyChanges: 0, keyChangesAfterSync: 0, last: "", left: false }; }
    function sample(): void {
        const r = probe.rec;
        if (!r.keys) return;
        const k = popup._phaseSteps.map(s => s.key).join(",");
        if (k !== r.last) {
            r.keyChanges++;
            if (r.left) r.keyChangesAfterSync++;
            r.last = k;
        }
        const cs = popup._currentStep;
        if (cs !== "" && cs !== "sync" && cs !== "resolve") r.left = true;
        if (cs !== "" && (r.steps.length === 0 || r.steps[r.steps.length - 1] !== cs)) r.steps.push(cs);
        const pc = prog.percent;
        if (r.percent.length === 0 || r.percent[r.percent.length - 1] !== pc) r.percent.push(pc);
    }
    Timer { interval: 8; repeat: true; running: probe.run; onTriggered: probe.sample() }
    function keys(): string { return popup._phaseSteps.map(s => s.key).join(","); }
    function monotone(list: var): bool { for (let i = 1; i < list.length; i++) if (list[i] < list[i - 1]) return false; return true; }
    // the Text with an objectName, anywhere under the popup
    function findObj(it: Item, name: string): var {
        if (!it) return null;
        if (it.objectName === name) return it;
        for (let i = 0; i < it.children.length; i++) {
            const r = probe.findObj(it.children[i], name);
            if (r) return r;
        }
        return null;
    }
    function waitFor(cond: var, ms: int): var {
        return w => cond() ? true : (w > ms ? true : "wait");
    }

    Component.onCompleted: Qt.callLater(() => {
        if (!probe.run) { Qt.quit(); return; }
        const S = [];
        const add = f => S.push(f);

        // ---------------- S1: a large update, the hook says done ----------------
        add(probe.after(() => { probe.startRec(); probe.begin("update"); }, 60));
        add(probe.after(() => probe.feed(probe.headPre(45, 0)), 700));
        add(w => {
            probe.check("S1.notch", probe.keys() === "sync,resolve,download,snapshot,install,hooks",
                        "a large update has a Snapshot notch between Download and Install: " + probe.keys());
            return true;
        });
        // pacman's integrity checks and the hook's block, until its first lines
        add(probe.after(() => probe.feed(probe.headInt), 500));
        add(w => {
            probe.check("S1.atSnapshot", popup._currentStep === "snapshot", "the ball waits at the Snapshot notch through the verification and the hook's start: " + popup._currentStep);
            return true;
        });
        add(probe.after(() => probe.feed([probe.hookDone[0], probe.hookDone[1]]), 500));
        add(w => {
            probe.check("S1.running", pp.snapshotState === "running" && Math.abs(pp.snapshotProgress - 0.35) < 1e-9
                        && pp.subPhase === "L4_PREHOOKS" && pp.snapshotText.indexOf("112 packages") === 0,
                        "state running at 35 %, sub-phase still L4_PREHOOKS: " + pp.snapshotState + " " + pp.snapshotProgress + " " + pp.subPhase);
            probe.check("S1.title", popup._phaseLabel === "Taking a snapshot", "the title says it: '" + popup._phaseLabel + "'");
            probe.check("S1.op", popup._currentOperation === "before updating linux, mesa and nvidia-open and 109 more" || popup._currentOperation.indexOf("before updating linux, mesa") === 0,
                        "the line names what it is for: '" + popup._currentOperation + "'");
            const pt = probe.findObj(popup, "snapPercent");
            probe.check("S1.figure", !!pt && pt.visible && pt.text === "35 %" && popup._progressTotal < 0,
                        "the card's figure is the hook's percent, '35 %': '" + (pt ? pt.text : "none") + "'");
            probe.check("S1.stepProgress", Math.abs(popup._stepProgress - 0.35) < 0.01, "the ball creeps with it: " + popup._stepProgress);
            return true;
        });
        add(probe.grab("snapshot_running_normal"));
        add(probe.mode("quiet"));
        add(probe.after(() => {}, 700));
        add(probe.grab("snapshot_running_quiet"));
        add(probe.mode("normal"));
        add(probe.after(() => probe.feed([probe.hookDone[2], probe.hookDone[3], probe.hookDone[4]]), 400));
        add(w => {
            probe.check("S1.done", pp.snapshotState === "done" && pp.snapshotShort === "6a493314" && pp.snapshotProgress === 1,
                        "done with the short id: " + pp.snapshotState + " " + pp.snapshotShort);
            return true;
        });
        add(probe.after(() => probe.feed(probe.installLines(3)), 700));
        add(probe.grab("snapshot_done_install"));
        // a hook line outside the pre-transaction hooks is not read (S6)
        add(probe.after(() => probe.feed(["lares-snapshot: failed internal late line"]), 100));
        add(w => {
            probe.check("S6.outside", pp.snapshotState === "done" && pp.errorCount === 0,
                        "a hook line in the post-transaction hooks changes nothing: " + pp.snapshotState + " errors " + pp.errorCount);
            return true;
        });
        add(probe.after(() => probe.end(0), 500));
        add(w => {
            const r = probe.rec;
            probe.check("S1.rail", r.keyChangesAfterSync === 0, "the notch list never re-spaced once the ball left Sync (" + r.keyChanges + " changes in all): " + r.steps.join(">"));
            const final = ["sync", "resolve", "download", "snapshot", "install", "hooks"];
            const idx = r.steps.map(k => final.indexOf(k));
            probe.check("S1.order", probe.monotone(idx) && idx.indexOf(3) >= 0 && idx.indexOf(3) < idx.indexOf(4),
                        "the ball went download > snapshot > install and never back: " + r.steps.join(">"));
            probe.check("S1.figureUp", probe.monotone(r.percent) && r.percent[r.percent.length - 1] === 100,
                        "the whole-run figure never went back and ends at 100: " + r.percent.join(","));
            probe.check("S1.complete", pp.phase === "COMPLETE" && pp.errorCount === 0 && popup._phaseLabel === "Update complete", "the run completes clean");
            return true;
        });
        add(probe.grab("snapshot_complete_idle"));

        // ---------------- S10: the service is not ready until the download: the notch comes late, the figure holds ----------------
        add(probe.after(() => { snaps.ready = false; probe.startRec(); probe.begin("update"); }, 60));
        add(probe.after(() => probe.feed(probe.headPre(45, 0)), 700));
        add(w => {
            probe.check("S10.nonotch", probe.keys() === "sync,resolve,download,install,hooks", "a service that is not ready asks for no notch: " + probe.keys());
            snaps.ready = true;
            return true;
        });
        add(probe.after(() => {}, 500));
        // the download moves after the notch joined the plan: the figure must hold (a plan that gained a step has a bigger total)
        add(probe.after(() => probe.feed([" Total (10/45)   9.0 MiB  3.0 MiB/s 00:04 [######] 20%"]), 300));
        add(w => {
            probe.check("S10.notch", probe.keys() === "sync,resolve,download,snapshot,install,hooks", "ready while the run downloads: the rule is asked and the notch is added: " + probe.keys());
            return true;
        });
        add(probe.after(() => probe.feed(probe.headInt), 400));
        add(probe.after(() => probe.feed(probe.hookDone), 500));
        add(probe.after(() => probe.feed(probe.installLines(3)), 700));
        add(probe.after(() => probe.end(0), 500));
        add(w => {
            const r = probe.rec;
            const fin = ["sync", "resolve", "download", "snapshot", "install", "hooks"];
            probe.check("S10.late", probe.monotone(r.steps.map(k => fin.indexOf(k))) && r.steps.indexOf("snapshot") >= 0,
                        "the ball goes through the late notch and never back: " + r.steps.join(">"));
            probe.check("S10.figureUp", probe.monotone(r.percent) && r.percent[r.percent.length - 1] === 100,
                        "the figure never went back although the plan gained a step mid-run: " + r.percent.join(","));
            return true;
        });

        // ---------------- S2: a small update: no notch, the hook skips ----------------
        add(probe.after(() => { probe.startRec(); probe.begin("update"); }, 60));
        add(probe.after(() => probe.feed(probe.head(10, 0)), 700));
        add(w => {
            probe.check("S2.nonotch", probe.keys() === "sync,resolve,download,install,hooks", "10 packages: no Snapshot notch: " + probe.keys());
            return true;
        });
        add(probe.after(() => probe.feed(["lares-snapshot: skip small 10 packages, below 40", "(2/2) Remove old stuff..."]), 500));
        add(w => {
            probe.check("S2.skipped", pp.snapshotState === "skipped" && pp.snapshotCode === "small" && pp.errorCount === 0,
                        "skipped, code small, no error: " + pp.snapshotState + " " + pp.snapshotCode);
            probe.check("S2.stillNoNotch", probe.keys() === "sync,resolve,download,install,hooks" && popup._currentStep === "install",
                        "a skip adds no notch and the ball is on Install: " + probe.keys() + " " + popup._currentStep);
            probe.check("S2.title", popup._phaseLabel !== "Taking a snapshot", "no snapshot title for a skip: '" + popup._phaseLabel + "'");
            return true;
        });
        add(probe.after(() => probe.end(0), 300));

        // ---------------- S3: a notch, and the hook answers `skip run` ----------------
        add(probe.after(() => probe.begin("update"), 60));
        add(probe.after(() => probe.feed(probe.head(45, 0)), 700));
        add(probe.after(() => probe.feed(["lares-snapshot: skip run a snapshot of this run exists", "(2/2) Remove old stuff..."]), 500));
        add(w => {
            probe.check("S3.settled", pp.snapshotState === "skipped" && pp.snapshotCode === "run" && probe.keys().indexOf("snapshot") >= 0
                        && popup._currentStep === "install",
                        "a later skip settles the notch (ball on Install), the notch stays: " + pp.snapshotState + " " + probe.keys() + " " + popup._currentStep);
            return true;
        });
        add(probe.after(() => probe.end(0), 300));

        // ---------------- S4: the snapshot fails ----------------
        add(probe.after(() => probe.begin("update"), 60));
        add(probe.after(() => probe.feed(probe.head(45, 0)), 700));
        add(probe.after(() => probe.feed(["lares-snapshot: start 112 packages: linux, mesa",
                                          "lares-snapshot: failed space 4.2 GB free after the update, 10 GB needed"]), 300));
        add(probe.after(() => probe.feed(["error: failed to commit transaction (failed to run transaction hooks)",
                                          "error: failed to run transaction hooks"]), 100));
        add(probe.after(() => probe.end(1), 900));
        add(w => {
            probe.check("S4.state", pp.snapshotState === "failed" && pp.snapshotCode === "space", "state failed, code space: " + pp.snapshotState + " " + pp.snapshotCode);
            const e0 = pp.errors.count > 0 ? pp.errors.get(0) : null;
            probe.check("S4.oneError", pp.errorCount === 1 && !!e0 && e0.pkg === "snapshot" && e0.reason.indexOf("free disk space") >= 0,
                        "ONE error, of package snapshot, in plain words (pacman's vaguer line adds none): " + pp.errorCount + " " + (e0 ? e0.pkg + ": " + e0.reason : ""));
            probe.check("S4.ball", popup._currentStep === "snapshot" && popup._outcome === "failed", "the ball stays where the run stopped (the Snapshot notch): " + popup._currentStep);
            probe.check("S4.title", popup._idleHeadline === "No snapshot, so nothing was installed", "the card's title: '" + popup._idleHeadline + "'");
            probe.check("S4.reason", popup._idleSubtext.indexOf("Not enough free disk space") === 0 && popup._idleSubtext.indexOf("10 GB needed") > 0,
                        "the line under it is the reason: '" + popup._idleSubtext + "'");
            const nb = probe.findObj(popup, "noSnapshotButton"), rb = probe.findObj(popup, "retryButton");
            probe.check("S4.buttons", !!nb && nb.visible && !!rb && rb.visible && nb.x + nb.width <= rb.x + 1,
                        "'Update without it' and 'Retry' are on the card, side by side");
            if (nb && nb.visible) nb.clicked();
            probe.check("S4.signal", probe.endCount === 1, "'Update without it' emits startWithoutSnapshotRequested: " + probe.endCount);
            return true;
        });
        add(probe.mode("quiet"));
        add(probe.after(() => {}, 700));
        add(probe.grab("snapshot_failed_quiet"));
        add(probe.mode("normal"));
        add(probe.after(() => {}, 600));
        add(probe.grab("snapshot_failed_normal"));

        // ---------------- S5: two transactions in one run ----------------
        add(probe.after(() => probe.begin("update"), 60));
        add(probe.after(() => probe.feed(probe.head(45, 1)), 700));
        add(probe.after(() => probe.feed(probe.hookDone), 300));
        add(probe.after(() => probe.feed(probe.installLines(2).concat([
            "loading packages...", "resolving dependencies...", "looking for conflicting packages...",
            "Package (1)  Old Version  New Version  Net Change", "aurpkg1  1.0-1  1.1-1  0.10 MiB",
            ":: Running pre-transaction hooks...", "(1/1) Taking a system snapshot...",
            "lares-snapshot: skip run a snapshot of this run exists"])), 500));
        add(w => {
            probe.check("S5.kept", pp.snapshotState === "done" && pp.snapshotShort === "6a493314",
                        "the second transaction's `skip run` leaves the first one's snapshot done: " + pp.snapshotState + " " + pp.snapshotShort);
            return true;
        });
        add(probe.after(() => probe.end(0), 300));

        // ---------------- S7: an undo run ----------------
        add(probe.after(() => { probe.startRec(); probe.begin("undo"); }, 60));
        add(probe.after(() => probe.feed(["loading packages...", "resolving dependencies...", "looking for conflicting packages...",
                                          "Package (3)  Old Version  New Version  Net Change",
                                          "linux  7.3.5-1  7.3.4-1  -3.00 MiB", "mesa  26.1-1  26.0-1  -1.00 MiB", "zlib  1.3-2  1.3-1  0.00 MiB",
                                          "Total Installed Size:  60.00 MiB", "Net Upgrade Size:  -4.00 MiB"]), 700));
        add(w => {
            probe.check("S7.steps", probe.keys() === "resolve,snapshot,install,hooks", "an undo has Resolve, Snapshot (the rule: linux), Install, Hooks: " + probe.keys());
            probe.check("S7.title", popup._phaseLabel === "Undoing the update", "its own title: '" + popup._phaseLabel + "'");
            probe.check("S7.official", pp.packages.count === 3 && !pp.packages.get(0).isAur && pp.aurBuildsTotal === 0 && !popup._hasAurWork,
                        "the table's rows are official packages: " + pp.packages.count + " rows, aur " + pp.aurBuildsTotal);
            return true;
        });
        add(probe.after(() => probe.feed([":: Running pre-transaction hooks...", "(1/1) Taking a system snapshot...",
                                          "lares-snapshot: start 3 packages: linux, mesa, zlib", "lares-snapshot: progress 50"]), 500));
        add(w => {
            probe.check("S7.snapshot", popup._currentStep === "snapshot" && popup._phaseLabel === "Taking a snapshot"
                        && popup._currentOperation === "before downgrading linux, mesa and zlib",
                        "the hook runs inside an undo too: " + popup._currentStep + " / '" + popup._currentOperation + "'");
            return true;
        });
        add(probe.grab("undo_snapshot"));
        add(probe.after(() => probe.feed(["lares-snapshot: done 7b6b6b6b added=1 seconds=2", ":: Processing package changes...",
                                          "(1/3) downgrading linux                       [######] 100%"]), 600));
        add(w => {
            probe.check("S7.install", popup._currentStep === "install" && popup._phaseLabel === "Downgrading packages"
                        && popup._currentOperation === "downgrading linux",
                        "Downgrading, one step: " + popup._currentStep + " / '" + popup._phaseLabel + "' / '" + popup._currentOperation + "'");
            return true;
        });
        add(probe.grab("undo_install"));
        add(probe.after(() => probe.feed(["(2/3) downgrading mesa", "(3/3) downgrading zlib", ":: Running post-transaction hooks...",
                                          "(1/1) Arming ConditionNeedsUpdate..."]), 300));
        add(probe.after(() => probe.end(0), 700));
        add(w => {
            probe.check("S7.end", pp.phase === "COMPLETE" && popup._idleHeadline === "Update undone",
                        "it ends 'Update undone': " + pp.phase + " / '" + popup._idleHeadline + "'");
            probe.check("S7.never", probe.rec.steps.indexOf("sync") < 0 && probe.rec.steps.indexOf("download") < 0,
                        "the ball was never on a sync or download notch: " + probe.rec.steps.join(">"));
            return true;
        });
        add(probe.after(() => { pp.runKind = "update"; }, 50));

        // ---------------- S8: the idle companion line ----------------
        add(probe.after(() => {}, 700));
        add(w => {
            const t = probe.findObj(popup, "snapLine");
            probe.check("S8.words", !!t && t.visible && t.text === "Snapshot 3 h ago", "the line reads the newest row: '" + (t ? t.text : "none") + "'");
            return true;
        });
        add(w => {
            const tb = probe.findObj(popup, "textBlock");
            probe.hWith = tb ? tb.implicitHeight : -1;
            snaps.rows = [];
            return true;
        });
        add(probe.after(() => {}, 300));
        add(w => {
            const t = probe.findObj(popup, "snapLine"), tb = probe.findObj(popup, "textBlock");
            probe.check("S8.empty", !!t && t.text === "No snapshot yet", "ready with no row: '" + (t ? t.text : "none") + "'");
            probe.check("S8.height", !!tb && tb.implicitHeight === probe.hWith, "the words change, the height does not: " + probe.hWith + " -> " + (tb ? tb.implicitHeight : -1));
            const area = probe.findObj(popup, "snapLineArea");
            popup.secondaryOpen = false;
            if (area) area.clicked(null);
            probe.check("S8.click", popup.secondaryOpen === true, "a click on the line opens the page");
            if (area) area.clicked(null);
            probe.check("S8.clickAgain", popup.secondaryOpen === false, "and again closes it");
            popup.secondaryOpen = true;
            probe.check("S8.stepBack", popup.stepBack() === true && popup.secondaryOpen === false && popup.stepBack() === false, "stepBack closes the page, and says whether one was open");
            return true;
        });
        add(probe.grab("idle_line_empty"));
        add(w => {
            const tb = probe.findObj(popup, "textBlock");
            snaps.ready = false;
            probe.hReady = tb ? tb.implicitHeight : -1;
            return true;
        });
        add(probe.after(() => {}, 300));
        add(w => {
            const t = probe.findObj(popup, "snapLine");
            probe.check("S8.notReady", !t || !t.visible, "a service that is not ready shows no line");
            snaps.ready = true;
            return true;
        });

        // ---------------- S11: the waiting list is refreshed after an undo too ----------------
        add(probe.after(() => { svc.runKind = "undo"; probe.refreshes = 0; svc.backend.exited(0, 0); }, 500));
        add(w => {
            probe.check("S11.undoRefresh", probe.refreshes >= 1, "an undo's end refreshes the waiting updates (what it took back is upgradable again): " + probe.refreshes);
            return true;
        });

        // ---------------- S12: real captures ----------------
        for (const t of [["snapshot-done", "update", "done", ""], ["snapshot-skip", "update", "skipped", "small"],
                         ["snapshot-failed", "update", "failed", "space"], ["undo", "undo", "done", ""], ["undo-week", "undo", "done", ""],
                         ["undo-conflict", "undo", "", ""], ["undo-big-update", "undo", "", ""]]) {
            const name = t[0], kind = t[1], state = t[2], code = t[3];
            add(probe.after(() => probe.begin(kind), 60));
            // (the skip and the failure were taken from a plain `pacman -S`: the line a `yay -Syu` transaction opens with is put before them)
            add(probe.after(() => probe.feed((name === "snapshot-skip" || name === "snapshot-failed" ? [":: Starting full system upgrade..."] : []).concat(probe.realLines(name))), 300));
            add(probe.after(() => probe.end(probe.real[name] ? probe.real[name].code : -1), 300));
            add(probe.after(() => {}, 300));
            add(w => {
                const n = probe.realLines(name).length;
                probe.check("S12." + name + ".lines", n > (name === "undo-big-update" ? 1 : 20), "the capture was read: " + n + " lines");
                if (state !== "")
                    probe.check("S12." + name + ".state", pp.snapshotState === state && (code === "" || pp.snapshotCode === code),
                                "the snapshot is " + state + ": " + pp.snapshotState + " " + pp.snapshotCode);
                const e0 = pp.errors.count > 0 ? pp.errors.get(0) : null;
                const said = pp.errorCount + (e0 ? " " + e0.pkg + ": " + e0.reason : "");
                if (name === "snapshot-failed")
                    probe.check("S12." + name + ".errors", pp.errorCount === 1 && !!e0 && e0.pkg === "snapshot", "one error, the snapshot's: " + said);
                else if (name === "undo-big-update")
                    probe.check("S12." + name + ".errors", pp.errorCount === 1 && pp.phase === "FAILED" && !!e0 && e0.pkg === "undo" && pp.snapshotState === "",
                                "the plan's own refusal (exit 4): one error, not yay's: " + pp.phase + " " + said);
                else if (name === "undo-conflict")
                    probe.check("S12." + name + ".errors", pp.errorCount >= 1 && pp.phase === "FAILED" && pp.snapshotState !== "failed"
                                && said.indexOf("conflicting files") > 0, "pacman's refusal is the error, the snapshot is not blamed: " + pp.phase + " " + said);
                else
                    probe.check("S12." + name + ".errors", pp.errorCount === 0 && pp.phase === "COMPLETE", "a clean end: " + pp.phase + " " + said);
                return true;
            });
        }

        // ---------------- S9: no service ----------------
        add(probe.after(() => { probe.serviceOn = false; }, 100));
        add(probe.after(() => probe.begin("update"), 60));
        add(probe.after(() => probe.feed(probe.head(45, 0)), 700));
        add(probe.after(() => probe.feed(probe.hookDone), 500));
        add(w => {
            probe.check("S9.nonotch", probe.keys() === "sync,resolve,download,install,hooks",
                        "with no service there is no notch, even while a hook speaks: " + probe.keys());
            return true;
        });
        add(probe.after(() => probe.end(0), 500));
        add(w => {
            const t = probe.findObj(popup, "snapLine");
            probe.check("S9.noline", !t || !t.visible, "and no line");
            return true;
        });

        probe.steps = S;
        probe.stepStarted = Date.now();
        driver.start();
    })
    property real hWith: -1
    property real hReady: -1
}
