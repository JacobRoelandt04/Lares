pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "modules/common/theme"
import "modules/bar/system_update/snapshots"
import "modules/bar/system_update/snapshots/SnapshotWords.js" as Words
import "modules/bar/system_update/snapshots/SnapshotFixtures.js" as Fixtures

// =============================================================================
// snapshot_ui_probe.qml -- the SnapshotService and the snapshots page (docs/contracts/snapshots.md section 11), live against STUBS of the
// root tool, pkexec, pkcheck, systemd-run and the user's tool (tools/dev/snapshot_ui_probe.sh makes them in a private dir and logs argv).
//
//   P1 missing    no root tool: phase "missing", ready false, no row, no error, nothing started but `test -x`
//   P2 rows       the tool's JSON -> rows newest first, the title, the notable packages, the off-site mark; the rule's answer
//   P3 cards      one open card at a time, the newest by default; a pick moves it
//   P4 undo       the plan loads on open; Undo is dead while a run is on and when the plan puts nothing back; the plan line's words
//   P5 verbs      keep / delete go pkcheck then pkexec with the right argv; Delete is gone on a kept card; a refusal is "Not allowed." and pkexec never runs
//   P6 refresh    a change of state.json and the end of a run read again; a refresh keeps every card (delegate identity) and inserts the new one on top
//   P7 offsite    a copy starts `systemd-run --user ...` once a day, never during a run, two minutes (here 0.7 s) after a run that made a snapshot; a mock never;
//                 a copy that waits for the charger starts when it goes in, and what it waits for is said from the battery as it is NOW
//   P8 height     the page asks for the cards' TARGET height at once (the engine eases; the content does not run ahead); a list that goes on
//                 is cut inside a card, never between two
// Bare it quits at once (no SUP_RUN). `SUP ok|FAIL <id>: what`, then `SUP DONE PASS|FAIL`.
// =============================================================================
// qmllint disable missing-property
ShellRoot {
    id: probe
    settings.watchFiles: false
    readonly property bool run: Quickshell.env("SUP_RUN") === "1"
    readonly property string stub: Quickshell.env("SUP_STUB") || ""
    property int checks: 0
    property int fails: 0
    property var failedTexts: []
    function check(id: string, ok: bool, what: string): void {
        probe.checks++;
        if (!ok)
            probe.fails++;
        console.log("SUP " + (ok ? "ok  " : "FAIL ") + id + ": " + what);
    }
    Timer {
        interval: 0
        running: !probe.run
        onTriggered: Qt.quit()
    }

    function findObj(it: Item, name: string): var {
        if (!it)
            return null;
        if (it.objectName === name)
            return it;
        for (let i = 0; i < it.children.length; i++) {
            const r = probe.findObj(it.children[i], name);
            if (r)
                return r;
        }
        return null;
    }
    component Log: FileView {
        blockLoading: true
        blockAllReads: true
        printErrors: false
        watchChanges: false
    }
    Log { id: logSys; path: probe.stub + "/sysrun.log" }
    Log { id: logPx; path: probe.stub + "/pkexec.log" }
    Log { id: logPc; path: probe.stub + "/pkcheck.log" }
    Log { id: logRoot; path: probe.stub + "/root.log" }
    Log { id: logUser; path: probe.stub + "/usertool.log" }
    function lines(file: string): var {
        const v = file === "sysrun.log" ? logSys : file === "pkexec.log" ? logPx : file === "pkcheck.log" ? logPc : file === "root.log" ? logRoot : logUser;
        v.reload();
        return v.text().split("\n").filter(l => l.length > 0);
    }

    // ---- the services ----------------------------------------------------------------------------------------
    component Svc: SnapshotService {
        live: true
        pkexec: probe.stub + "/pkexec"
        pkcheck: probe.stub + "/pkcheck"
        systemdRun: probe.stub + "/systemd-run"
        python: "python3"
        userTool: probe.stub + "/usertool.py"
        offsiteTool: "/stub/lares-offsite"
        statePath: probe.run ? probe.stub + "/state.json" : ""
        onFailed: text => probe.failedTexts = probe.failedTexts.concat([text])
    }
    Svc {
        id: svcM
        rootTool: "/nonexistent/lares-snapshot-root"
        statePath: ""
    }
    Svc {
        id: svcA
        rootTool: probe.stub + "/root"
        offsitePath: probe.run ? probe.stub + "/offsite.json" : ""
        configPath: probe.run ? probe.stub + "/cfgA/config/snapshots.jsonc" : ""
    }
    property bool oRun: true
    Svc {
        id: svcO
        rootTool: probe.stub + "/root"
        statePath: ""
        runActive: probe.oRun
        offsitePath: probe.run ? probe.stub + "/offsiteO.json" : ""
        configPath: probe.run ? probe.stub + "/cfgO/config/snapshots.jsonc" : ""
        offsiteAfterRunMs: 700
        offsiteCheckMs: 250
    }
    Svc {
        id: svcP
        rootTool: probe.stub + "/root"
        statePath: ""
        onBattery: true
        offsitePath: probe.run ? probe.stub + "/offsiteP.json" : ""
        configPath: probe.run ? probe.stub + "/cfgO/config/snapshots.jsonc" : ""
        offsiteCheckMs: 100000000
        offsiteAfterRunMs: 100000000
        offsitePlugMs: 60
    }
    SnapshotService {
        id: svcL
        live: false
        mockRecords: Fixtures.records(Date.now())
        mockOffsite: ({ state: "idle", lastOk: 1000, pending: { files: 0, bytes: 0 }, done: { files: 0, bytes: 0 }, snapshots: [] })
    }
    SnapshotService {
        id: svcK
        live: false
        offsiteAfterRunMs: 700
        offsiteCheckMs: 250
        mockOffsite: ({ state: "idle", lastOk: 1000, pending: { files: 0, bytes: 0 }, done: { files: 0, bytes: 0 }, snapshots: [] })
    }

    Window {
        id: win
        visible: true
        width: 420
        height: 700
        color: Theme.surface
        SnapshotsPage {
            id: pageL
            visible: false
            service: svcL
            fontFamily: "Inter"
            pageWidth: 380
            openMs: 0
        }
        SnapshotsPage {
            id: page
            service: svcA
            fontFamily: "Inter"
            runActive: probe.pageRun
            pageWidth: 380
            openMs: 60
            onUndoRequested: short => probe.undoAsked = short
        }
    }
    property bool pageRun: false
    property string undoAsked: ""

    // ---- the sequence ------------------------------------------------------------------------------------------
    property int _i: 0
    property real _t0: 0
    property var steps: []
    property var scratch: ({})
    Timer {
        interval: 40
        repeat: true
        running: probe.run
        onTriggered: {
            if (probe._i >= probe.steps.length) {
                running = false;
                console.log("SUP DONE " + (probe.fails === 0 && probe.checks > 0 ? "PASS" : "FAIL") + " (" + (probe.checks - probe.fails) + "/" + probe.checks + ")");
                Qt.quit();
                return;
            }
            if (probe._t0 === 0)
                probe._t0 = Date.now();
            const w = Date.now() - probe._t0;
            let r;
            try {
                r = probe.steps[probe._i](w);
            } catch (e) {
                probe.check("run." + probe._i, false, "a step threw: " + e);
                r = true;
            }
            if (r === "wait" && w < 8000)
                return;
            if (r === "wait")
                probe.check("run.timeout" + probe._i, false, "a step waited 8 s");
            probe._i++;
            probe._t0 = 0;
        }
    }
    function cardAt(i: int): var {
        return page.cards.itemAt(i);
    }
    function openCards(): var {
        const out = [];
        for (let i = 0; i < page.cards.count; i++)
            if (page.cards.itemAt(i).open)
                out.push(i);
        return out;
    }
    function after(f: var, ms: int): var {
        return w => {
            if (w < ms)
                return "wait";
            f();
            return true;
        };
    }

    Component.onCompleted: Qt.callLater(() => {
        if (!probe.run) {
            Qt.quit();
            return;
        }
        probe.stub_list2 = Quickshell.env("SUP_LIST2") || "";
        probe.stub_list3 = Quickshell.env("SUP_LIST3") || "";
        const S = probe.steps = [];
        const add = f => S.push(f);
        const P = probe.stub;

        // ---------------- P1: no tool ----------------
        add(w => (svcM.phase === "missing" && svcA.phase === "ready") ? true : "wait");
        add(w => {
            probe.check("P1.missing", svcM.phase === "missing" && svcM.ready === false && svcM.rows.length === 0,
                        "no root tool: phase " + svcM.phase + ", ready " + svcM.ready + ", rows " + svcM.rows.length);
            const runs = svcM.calls.filter(c => c.indexOf("run ") === 0);
            probe.check("P1.quiet", runs.length === 1 && runs[0].indexOf("run test -x") === 0 && probe.failedTexts.length === 0,
                        "only `test -x` ran and nothing was said: " + JSON.stringify(runs) + " failed=" + probe.failedTexts.length);
            probe.check("P1.wants", svcM.wantsFor(["linux"]).want === false, "a missing tool wants no snapshot");
        });

        // ---------------- P2: rows ----------------
        add(w => (svcA.rows.length === 3 && !!svcA.offsite.state) ? true : "wait");
        add(w => {
            const r = svcA.rows;
            probe.check("P2.order", r.length === 3 && r[0].short === "aaaa1111" && r[1].short === "bbbb2222" && r[2].short === "cccc3333",
                        "newest first: " + r.map(x => x.short).join(","));
            probe.check("P2.title", r[0].title === "Before 112 packages" && r[2].title === "Manual", "titles: " + r.map(x => x.title).join(" | "));
            probe.check("P2.notable", r[0].notable.length === 2 && r[0].notable[0].name === "linux" && r[0].notable[0].from === "7.3.4.arch1-1" && r[0].notable[0].to === "7.3.5.arch1-1",
                        "notable with from -> to: " + JSON.stringify(r[0].notable));
            probe.check("P2.offsite", r[0].offsite === true && r[1].offsite === false, "the off-site mark follows offsite.json: " + r[0].offsite + "," + r[1].offsite);
            probe.check("P2.rule", svcA.wantsFor(["linux", "a"]).want === true && svcA.wantsFor(["a", "b"]).want === false, "the rule answers through the tool's settings");
            probe.check("P2.model", svcA.model.count === 3 && svcA.model.get(0).short === "aaaa1111", "the model mirrors the rows");
            probe.scratch.refresh0 = svcA.refreshCount;
        });

        // ---------------- P3: one open card ----------------
        add(w => page.cards.count === 3 ? true : "wait");
        add(probe.after(() => {
            const o = probe.openCards();
            probe.check("P3.default", o.length === 1 && o[0] === 0, "the newest card is open by default: " + JSON.stringify(o));
            probe.cardAt(2).toggled();
        }, 200));
        add(probe.after(() => {
            const o = probe.openCards();
            probe.check("P3.oneOpen", o.length === 1 && o[0] === 2, "a click opens that card and shuts the other: " + JSON.stringify(o));
            probe.cardAt(2).toggled();
        }, 200));
        add(probe.after(() => {
            probe.check("P3.shut", probe.openCards().length === 0, "a click on the open card shuts it: " + JSON.stringify(probe.openCards()));
            probe.cardAt(0).toggled();
        }, 200));

        // ---------------- P4: the plan and Undo ----------------
        add(w => (svcA.undoPlans["aaaa1111"] && svcA.undoPlans["aaaa1111"].state === "ok") ? true : "wait");
        add(probe.after(() => {
            const c = probe.cardAt(0);
            const line = probe.findObj(c, "planLine"), undo = probe.findObj(c, "undoButton");
            probe.check("P4.line", !!line && line.text === "2 of 3 packages can be put back; 1 old version is gone.", "the plan's line: '" + (line ? line.text : "none") + "'");
            probe.check("P4.on", undo.enabled === true, "Undo is live when the plan puts packages back");
            probe.check("P4.argv", probe.lines("usertool.log").indexOf("undo-plan aaaa1111 --json") >= 0, "the plan is asked of the user's tool: " + probe.lines("usertool.log"));
            probe.pageRun = true;
        }, 200));
        add(probe.after(() => {
            const undo = probe.findObj(probe.cardAt(0), "undoButton");
            probe.check("P4.runoff", undo.enabled === false, "Undo is dead while an update runs");
            probe.pageRun = false;
        }, 150));
        add(probe.after(() => {
            const undo = probe.findObj(probe.cardAt(0), "undoButton");
            probe.check("P4.runon", undo.enabled === true, "Undo is back when the run ends");
            undo.clicked();
        }, 150));
        add(probe.after(() => {
            probe.check("P4.ask", probe.undoAsked === "aaaa1111", "Undo asks the host to start the undo run: '" + probe.undoAsked + "'");
            probe.cardAt(2).toggled();
        }, 100));
        add(w => (svcA.undoPlans["cccc3333"] && svcA.undoPlans["cccc3333"].state === "ok") ? true : "wait");
        add(probe.after(() => {
            const c = probe.cardAt(2);
            const undo = probe.findObj(c, "undoButton"), line = probe.findObj(c, "planLine");
            probe.check("P4.nothing", undo.enabled === false && line.text.indexOf("Nothing can be put back") === 0,
                        "a plan with no files: Undo dead, the line says so: '" + line.text + "'");
        }, 200));

        // ---------------- P5: keep, delete, refusal ----------------
        add(probe.after(() => {
            probe.cardAt(0).toggled();   // open the newest again
        }, 50));
        add(probe.after(() => {
            const c = probe.cardAt(0);
            probe.findObj(c, "keepButton").clicked();
        }, 250));
        add(w => probe.lines("pkexec.log").length >= 1 ? true : "wait");
        add(probe.after(() => {
            const pc = probe.lines("pkcheck.log"), px = probe.lines("pkexec.log");
            probe.check("P5.keep", pc.some(l => l.indexOf("--action-id org.lares.snapshot.keep --process ") >= 0) && px[0] === probe.stub + "/root keep aaaa1111 on",
                        "keep: pkcheck then pkexec of the root tool: " + JSON.stringify(pc) + " " + JSON.stringify(px));
            probe.scratch.pxBefore = px.length;
            probe.cardAt(1).toggled();   // bbbb2222 is kept in the stub list: open it, a shut card's buttons read invisible whatever they say
        }, 300));
        add(probe.after(() => {
            const k = probe.cardAt(1);
            const del = probe.findObj(k, "deleteButton"), keep = probe.findObj(k, "keepButton");
            probe.check("P5.hiddenKept", svcA.rows[1].keep === true && k.open && keep.visible === true && del.visible === false,
                        "Delete is gone on a kept open card (its Keep is not): keep=" + svcA.rows[1].keep + " keepVisible=" + keep.visible + " deleteVisible=" + del.visible);
            probe.cardAt(0).toggled();
        }, 250));
        add(probe.after(() => {
            probe.findObj(probe.cardAt(0), "deleteButton").clicked();
        }, 250));
        add(w => probe.lines("pkexec.log").length >= 2 ? true : "wait");
        add(probe.after(() => {
            const px = probe.lines("pkexec.log"), pc = probe.lines("pkcheck.log");
            probe.check("P5.delete", px[1] === probe.stub + "/root delete aaaa1111" && pc.some(l => l.indexOf("org.lares.snapshot.delete") >= 0),
                        "delete: no confirm of ours, pkcheck then pkexec: " + JSON.stringify(px));
            probe.check("P5.root", probe.lines("root.log").indexOf("keep aaaa1111 on") >= 0, "the root tool really ran the verb under pkexec: " + probe.lines("root.log"));
            probe.scratch.px = px.length;
            probe.scratch.failed0 = probe.failedTexts.length;
            // the tool says no
            probe.writeFile(probe.stub + "/pkcheck.code", "1");
        }, 300));
        add(probe.after(() => svcA.remove("bbbb2222"), 150));
        add(w => probe.failedTexts.length > probe.scratch.failed0 ? true : "wait");
        add(probe.after(() => {
            probe.check("P5.refused", probe.failedTexts[probe.failedTexts.length - 1] === "Not allowed." && probe.lines("pkexec.log").length === probe.scratch.px,
                        "a refused action says so and pkexec never ran: '" + probe.failedTexts[probe.failedTexts.length - 1] + "' px=" + probe.lines("pkexec.log").length);
            probe.check("P5.errorShown", svcA.lastError === "Not allowed.", "the page can show it: lastError '" + svcA.lastError + "'");
            probe.writeFile(probe.stub + "/pkcheck.code", "0");
        }, 300));

        // ---------------- P6: refresh, identity ----------------
        add(probe.after(() => {
            probe.scratch.items = [probe.cardAt(0), probe.cardAt(1), probe.cardAt(2)];
            probe.scratch.refresh1 = svcA.refreshCount;
            probe.writeFile(probe.stub + "/list.json", probe.stub_list2);
            probe.writeFile(probe.stub + "/state.json", String(Date.now()));
        }, 400));
        add(w => svcA.rows.length === 4 ? true : "wait");
        add(probe.after(() => {
            const it = probe.scratch.items;
            probe.check("P6.statewatch", svcA.refreshCount > probe.scratch.refresh1 && svcA.rows[0].short === "dddd4444",
                        "a change of state.json read the tool again: refreshes " + probe.scratch.refresh1 + " -> " + svcA.refreshCount + ", newest " + svcA.rows[0].short);
            probe.check("P6.identity", page.cards.count === 4 && page.cards.itemAt(1) === it[0] && page.cards.itemAt(2) === it[1] && page.cards.itemAt(3) === it[2],
                        "no card was rebuilt: the three old delegates are the same objects, one below the new one");
            probe.check("P6.open", probe.openCards().length === 1, "still one open card after the refresh: " + JSON.stringify(probe.openCards()));
            probe.scratch.refresh2 = svcA.refreshCount;
            svcO.runActive;   // (read)
        }, 300));

        // ---------------- P7: off site ----------------
        // svcO has been in a run since its start: nothing may have been started
        add(probe.after(() => {
            probe.check("P7.norun", probe.lines("sysrun.log").length === 0 && svcO.phase === "ready" && svcO.offsiteEnabled === true,
                        "no copy while a run is on (service ready, off-site enabled): sysrun=" + probe.lines("sysrun.log").length + " phase=" + svcO.phase + " enabled=" + svcO.offsiteEnabled);
            probe.check("P7.mock", svcK.calls.filter(c => c.indexOf("offsite") >= 0 || c.indexOf("run ") === 0).length === 0,
                        "a mock shell starts nothing: " + JSON.stringify(svcK.calls.filter(c => c.indexOf("offsite") >= 0 || c.indexOf("run ") === 0)));
            probe.oRun = false;
        }, 900));
        add(w => probe.lines("sysrun.log").length >= 1 ? true : "wait");
        add(probe.after(() => {
            const l = probe.lines("sysrun.log");
            probe.check("P7.daily", l.length === 1 && l[0] === "--user --unit=lares-offsite --collect --nice=10 --quiet --expand-environment=no --property=SuccessExitStatus=3 /stub/lares-offsite sync",
                        "a run's end with nothing new, and a day since the last copy: one systemd-run: " + JSON.stringify(l));
        }, 100));
        add(probe.after(() => {
            probe.check("P7.once", probe.lines("sysrun.log").length === 1, "at most once a day: still one after several checks: " + probe.lines("sysrun.log").length);
            probe.scratch.sys0 = 1;
            probe.oRun = true;
        }, 1200));
        // a run that makes a snapshot: the copy comes afterRunMs after it ends
        add(probe.after(() => {
            probe.writeFile(probe.stub + "/list.json", probe.stub_list3);
            probe.writeFile(probe.stub + "/state.json", "x" + Date.now());
        }, 300));
        add(probe.after(() => {
            svcO.refresh();
            probe.oRun = false;
            probe.scratch.endAt = Date.now();
        }, 400));
        add(probe.after(() => {
            probe.check("P7.notyet", probe.lines("sysrun.log").length === 1, "not before the delay: " + probe.lines("sysrun.log").length);
        }, 300));
        add(w => probe.lines("sysrun.log").length >= 2 ? true : "wait");
        add(probe.after(() => {
            const dt = Date.now() - probe.scratch.endAt;
            probe.check("P7.afterRun", probe.lines("sysrun.log").length === 2 && dt >= 650, "two (here 0.7) seconds after a run that made a snapshot: started after " + dt + " ms");
        }, 100));

        // the rule itself: what asks again, and when
        add(w => {
            const H = 3600000, now = 1000 * H;
            const due = o => Words.offsiteDue(Object.assign({ enabled: true, live: true, runActive: false, busy: "", offsiteState: "idle", lastOkMs: now - H,
                                                              lastTriggerMs: now - H, nowMs: now, runEndedMs: 0, newSinceRun: false, afterMs: 120000 }, o));
            const t = [["idle, an hour since the last", {}, ""], ["idle, a day", { lastOkMs: now - 25 * H, lastTriggerMs: now - 25 * H }, "daily"],
                       ["waiting, ten minutes", { offsiteState: "waiting", lastTriggerMs: now - H / 6 }, ""],
                       ["on battery, ten minutes", { offsiteState: "waiting", cause: "battery", onBattery: true, lastTriggerMs: now - H / 6 }, ""],
                       ["on battery, the page opened", { offsiteState: "waiting", cause: "battery", onBattery: true, looked: true, lastTriggerMs: now - H / 6 }, ""],
                       ["the charger is in", { offsiteState: "waiting", cause: "battery", onBattery: false, lastTriggerMs: now - 20000 }, "retry"],
                       ["the charger is in, 3 s after a try", { offsiteState: "waiting", cause: "battery", onBattery: false, lastTriggerMs: now - 3000 }, ""],
                       ["a locked keyring, six minutes", { offsiteState: "waiting", cause: "keyring", lastTriggerMs: now - H / 10 }, "retry"],
                       ["a locked keyring, a minute, the page opened", { offsiteState: "waiting", cause: "keyring", looked: true, lastTriggerMs: now - 61000 }, "retry"],
                       ["asked for a pause, six minutes", { offsiteState: "waiting", cause: "throttled", lastTriggerMs: now - H / 10 }, ""],
                       ["signed out, two minutes, the page opened", { offsiteState: "error", cause: "signin", looked: true, lastTriggerMs: now - 120000 }, "retry"],
                       ["idle, the page opened", { looked: true }, ""], ["waiting, half an hour", { offsiteState: "waiting", lastTriggerMs: now - H / 2 }, "retry"],
                       ["an error, an hour", { offsiteState: "error" }, ""], ["an error, three hours", { offsiteState: "error", lastTriggerMs: now - 3 * H }, "retry"],
                       ["running, an hour", { offsiteState: "running" }, ""], ["running left standing, a new shell", { offsiteState: "running", lastTriggerMs: 0 }, "retry"],
                       ["waiting during an update", { offsiteState: "waiting", lastTriggerMs: now - 9 * H, runActive: true }, ""], ["off", { enabled: false, offsiteState: "waiting", lastTriggerMs: 0 }, ""],
                       ["every 6 h (snapshots.jsonc offsite.everyHours), seven hours", { everyMs: 6 * H, lastOkMs: now - 7 * H, lastTriggerMs: now - 7 * H }, "daily"],
                       ["every 48 h, a day", { everyMs: 48 * H, lastOkMs: now - 25 * H, lastTriggerMs: now - 25 * H }, ""],
                       ["after an update", { newSinceRun: true, runEndedMs: now - 200000 }, "afterRun"],
                       ["after an update, offsite.afterUpdate false", { newSinceRun: true, runEndedMs: now - 200000, afterUpdate: false }, ""],
                       ["... the day still counts", { newSinceRun: true, runEndedMs: now - 200000, afterUpdate: false, lastOkMs: now - 25 * H, lastTriggerMs: now - 25 * H }, "daily"]];
            const bad = t.filter(r => due(r[1]) !== r[2]).map(r => r[0] + ": '" + due(r[1]) + "' for '" + r[2] + "'");
            probe.check("P7.rule", bad.length === 0, "the rule's table (" + t.length + "): " + (bad.length ? bad.join("; ") : "all as they must"));
            return true;
        });

        // the words: what it waits for is the battery's own word, never the file's old one
        add(w => {
            const at = Date.UTC(2026, 10, 22, 12), off = o => Words.offsiteLine(o, true, at, true), ac = o => Words.offsiteLine(o, true, at, false);
            const stale = { state: "waiting", cause: "battery", reason: "The machine is on battery; the copy waits for the charger." };
            const run = { state: "running", done: { files: 1, bytes: 1.24e9 }, pending: { files: 9, bytes: 11.5e9 } };
            const t = [[off(stale).text, "Proton Drive waits for the charger"], [ac(stale).text, "Proton Drive: the copy starts in a moment"],
                       [ac(run).text, "Copying to Proton Drive"], [ac(run).figure, "1.2 / 12.7 GB"], [ac(run).fraction.toFixed(3), "0.097"],
                       [ac({ state: "running" }).text, "Looking at Proton Drive"], [ac({ state: "running" }).fraction, -1],
                       [ac({ state: "waiting", cause: "keyring", reason: "x" }).text, "Proton Drive waits for the keyring (it opens with your password)"],
                       [ac({ state: "waiting", reason: "Something new." }).text, "Proton Drive: Something new."],
                       [ac({ state: "error", cause: "signin", reason: "x" }).text, "Proton Drive is signed out. Run proton-drive auth login"],
                       [ac({ state: "error", reason: "Broken." }).tone, "bad"], [Words.offsiteLine(run, false, at, false).text, ""]];
            const bad = t.filter(r => r[0] !== r[1]).map(r => "'" + r[0] + "' for '" + r[1] + "'");
            probe.check("P7.words", bad.length === 0, "the line's words (" + t.length + "): " + (bad.length ? bad.join("; ") : "all as they must"));
            return true;
        });
        // the charger: svcP waits for it, its file is fresh (no daily copy due), its timers are out of the way
        add(w => svcP.phase === "ready" && svcP.offsite.state === "waiting" ? true : (w < 4000 ? "wait" : (probe.check("P7.plugready", false, "the service never read its file: " + svcP.phase + " " + JSON.stringify(svcP.offsite)), true)));
        add(probe.after(() => {
            svcP._lastTriggerMs = Date.now() - 20000;
            probe.scratch.sysP = probe.lines("sysrun.log").length;
            svcP.look();
        }, 50));
        add(probe.after(() => {
            probe.check("P7.onbattery", probe.lines("sysrun.log").length === probe.scratch.sysP, "on battery the page's opening asks for nothing");
            svcP._lastTriggerMs = Date.now() - 20000;
            svcP.onBattery = false;
        }, 500));
        add(probe.after(() => {
            probe.check("P7.plug", probe.lines("sysrun.log").length === probe.scratch.sysP + 1, "the charger in: the copy starts, once (" + (probe.lines("sysrun.log").length - probe.scratch.sysP) + ")");
        }, 900));

        // ---------------- P8: height ----------------
        add(probe.after(() => {
            page.pick = "";
            page.openMs = 500;
            probe.scratch.nh0 = page.naturalHeight;
            probe.cardAt(page.cards.count - 1).toggled();
        }, 200));
        add(probe.after(() => {
            probe.scratch.nhNow = page.naturalHeight;
        }, 20));
        add(probe.after(() => {
            probe.check("P8.target", Math.abs(page.naturalHeight - probe.scratch.nhNow) < 1.5 && page.naturalHeight <= page.maxHeight + 0.5,
                        "the asked height is the target at once, the cards' own easing does not move it: " + probe.scratch.nhNow + " -> " + page.naturalHeight);
        }, 600));

        // a list longer than the page is cut inside a card: at least its title over the cut, at least its foot under it
        add(w => pageL.cards.count === 8 ? true : (w < 4000 ? "wait" : (probe.check("P8.cutready", false, "the long page has " + pageL.cards.count + " cards"), true)));
        add(probe.after(() => {
            const bad = [];
            let seen = 0;
            for (const pick of ["-", "6a493314", "c3d4e5f6", "1d2e3f40"])
                for (let mh = 430; mh <= 580; mh += 3) {
                    pageL.pick = pick;
                    pageL.maxHeight = mh;
                    const room = pageL.naturalHeight - pageL._chrome;
                    let y = 0, total = 0, part = null;
                    for (let i = 0; i < pageL.cards.count; i++) {
                        const h = pageL.cards.itemAt(i).targetHeight;
                        if (part === null && room < y + h + pageL.cardGap) part = { p: room - y, h: h };
                        y += h + pageL.cardGap;
                    }
                    if (y - pageL.cardGap <= room + 0.5) continue;       // it fits
                    seen++;
                    if (pageL.naturalHeight > mh + 0.5 || !part || part.p < 37 || part.p > part.h - 9)
                        bad.push(pick + " at " + mh + ": " + (part ? part.p.toFixed(0) + " of " + part.h.toFixed(0) : "past the end") + ", height " + pageL.naturalHeight);
                }
            probe.check("P8.cut", seen > 100 && bad.length === 0, seen + " long lists, every one cut inside a card" + (bad.length ? ": NOT " + bad.length + ", " + bad.slice(0, 2).join("; ") : ""));
        }, 600));

        // theme switch: nothing breaks and the page keeps its size
        add(probe.after(() => {
            const h = page.naturalHeight;
            Theme.toggleMode();
            probe.scratch.th = h;
        }, 100));
        add(probe.after(() => {
            probe.check("P9.theme", Math.abs(page.naturalHeight - probe.scratch.th) < 1, "a theme switch moves nothing: " + probe.scratch.th + " -> " + page.naturalHeight);
        }, 700));
    })

    property string stub_list2: ""
    property string stub_list3: ""
    FileView {
        id: writer
        printErrors: false
        watchChanges: false
        atomicWrites: false
        blockWrites: true
    }
    function writeFile(path: string, text: string): void {
        writer.path = "";
        writer.path = path;
        writer.setText(text);
    }
}
