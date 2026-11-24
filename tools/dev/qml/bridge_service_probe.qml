pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "modules/common/notify"
import "modules/common/components"
import "modules/common/osd"
import "modules/shell"
import "modules/bridge/data"
import "modules/bridge/data/BridgeModel.js" as Model
import "modules/bridge/data/BridgeScenarios.js" as Scenarios

// BridgeService on a STUB of tools/bridge/lares-bridge (a script that prints the lines this harness appends to its feed and answers
// the one-shots from a table, logging its argv and times), the toasts on a stub bus, the OSD on a stub service, the file picker and
// the clipboard on stubs. No phone, no adb, no KDE Connect, no daemon of the user's. Prints BSP lines and one
// `BRIDGE_SERVICE RESULT PASS|FAIL`. Runner: tools/dev/bridge_service_probe.sh (it sets the env).
Item {
    id: root
    width: 10
    height: 10

    readonly property string work: Quickshell.env("BSP_WORK") || ""
    readonly property string rm: "kdc:redmagic10pro"
    property int unlocksBefore: 0
    readonly property string px: "kdc:pixel6pro"
    property var posts: []
    property var withdrawn: []
    // posts and withdraws in the order they came
    property var events: []
    property var fails: []
    property int checks: 0
    function check(id, ok, detail) {
        root.checks++;
        console.log("BSP " + id + ": " + (ok ? "ok" : "FAIL") + (detail ? "  " + detail : ""));
        if (!ok)
            root.fails.push(id);
    }
    function stubBus() {
        NotificationBus.service = ({
            post: spec => { root.posts.push(spec); root.events.push("post " + spec.key); return "uid"; },
            withdraw: (source, key) => { root.withdrawn.push(key); root.events.push("withdraw " + key); },
            attend: () => {}
        });
    }
    function postsOf(key) { return root.posts.filter(p => p.key === key); }
    function resetToasts() { root.posts = []; root.withdrawn = []; root.events = []; }

    // the OSD's service: records what it is asked, and says whether it showed it
    property var osdReqs: []
    property bool osdUp: true
    function stubOsd() {
        OsdBus.service = ({ show: r => { root.osdReqs.push(r); return root.osdUp; } });
    }

    // ---- the stub tool's log ---------------------------------------------------------------------------------------------
    FileView { id: logView; blockLoading: true; blockAllReads: true; printErrors: false; watchChanges: false }
    function events_(dir) {
        logView.path = "";
        logView.path = root.work + "/" + dir + "/calls.log";
        logView.reload();
        return logView.text().trim().split("\n").filter(l => l !== "").map(l => JSON.parse(l));
    }
    // the argv of every one-shot that ENDED, in order of its end (the watcher is not one)
    function ended(dir) { return root.events_(dir).filter(e => e.ev === "end").map(e => e.argv); }
    function endedOf(dir, verb) { return root.ended(dir).filter(a => a[0] === verb); }
    function j(a) { return JSON.stringify(a); }

    // ---- the feed: one line appended at a time ---------------------------------------------------------------------------
    property var feedQ: []
    property bool feedBusy: false
    function feed(dir, obj, file) {
        root.feedQ.push({ dir: dir, file: file || "watch.in", text: typeof obj === "string" ? obj : JSON.stringify(obj) });
        root.feedNext();
    }
    function feedNext() {
        if (root.feedBusy || root.feedQ.length === 0)
            return;
        const f = root.feedQ.shift();
        root.feedBusy = true;
        feeder.command = ["sh", "-c", "printf '%s\\n' \"$1\" >> \"$2/$3\"", "sh", f.text, root.work + "/" + f.dir, f.file];
        feeder.running = true;
    }
    Process { id: feeder; onExited: code => { root.feedBusy = false; root.feedNext(); } }

    // ---- lines ---------------------------------------------------------------------------------------------------------
    function base() { return JSON.parse(Scenarios.lines("wired")[0]); }       // REDMAGIC on the cable, Pixel away; serial 1
    function lineOf(serial, mod) { const l = root.base(); l.serial = serial; if (mod) mod(l); return l; }
    function tablet() { return { key: "adb:T1", name: "Tab S9", type: "tablet", present: true, link: "usb" }; }
    function sendJob(id, over) {
        return Object.assign({ id: id, kind: "send", device: root.rm, mode: "", via: "adb", phase: "running", started: 100, ended: null, code: null, reason: "",
            files: 3, file: 0, name: "IMG_2041.jpg", done: 0, total: 12058624, rate: 0 }, over || {});
    }

    // ---- what is a Process ---------------------------------------------------------------------------------------------
    // a walk of an object's children (and an Instantiator's objects) for anything that has a `command` and `running`: a Process, or
    // the SupervisedStream that owns one
    function procs(o) {
        const seen = [];
        let n = 0;
        function walk(x) {
            if (!x || seen.indexOf(x) >= 0)
                return;
            seen.push(x);
            if (x.running !== undefined && x.command !== undefined)
                n++;
            if (typeof x.objectAt === "function" && typeof x.count === "number")
                for (let i = 0; i < x.count; i++)
                    walk(x.objectAt(i));
            const kids = x.data ? x.data : [];
            for (let i = 0; i < kids.length; i++)
                walk(kids[i]);
        }
        walk(o);
        return n;
    }

    // ---- the services under test ---------------------------------------------------------------------------------------
    DesktopNotifier { id: toastNotifier; appName: "Bridge" }
    CommandRunner { id: cmdRunner; live: false }
    QtObject {
        id: clipStub
        property var pastes: []
        function paste(keys, opts) { clipStub.pastes.push({ keys: keys, opts: opts }); }
    }
    Component {
        id: svcComp
        BridgeService {
            notifier: toastNotifier
            runner: cmdRunner
            clipboard: clipStub
        }
    }
    property var svcM: null      // not live
    property var svcL: null      // live, on the stub
    property var svcE: null      // live, whose first line carries ended jobs
    property var svcT: null      // live, with no tool
    property var actedT: []
    property var actedM: []
    property var actedL: []
    property var snaps: []
    property var errors: []
    Connections {
        target: root.svcM
        ignoreUnknownSignals: true
        function onActed(key, action, ok, why) { root.actedM.push([key, action, ok, why]); }
    }
    Connections {
        target: root.svcL
        ignoreUnknownSignals: true
        function onActed(key, action, ok, why) { root.actedL.push([key, action, ok, why]); }
        function onLastErrorChanged() { root.errors.push(root.svcL.lastError); }
        // what a handler on `serial` sees: the model publishes its identity last
        function onSerialChanged() {
            const s = root.svcL;
            root.snaps.push({ serial: s.serial, count: s.count, first: s.count > 0 ? s.devices.get(0).key : "", jobs: s.jobs.length, pairing: s.pairing.length,
                kdc: s.env.kdeconnect, cur: s.currentKey });
        }
    }

    // ---- steps: each waits for its own condition, on the wall clock (offscreen a QML Timer runs fast) ---------------------
    property var steps: []
    property int at: 0
    property double stepSince: 0
    function step(name, until, then, budgetMs) { root.steps.push({ name: name, until: until, then: then, budget: budgetMs || 8000 }); }
    Timer {
        id: tick
        interval: 40
        repeat: true
        onTriggered: {
            if (root.at >= root.steps.length) { tick.stop(); root.finish(); return; }
            const s = root.steps[root.at];
            if (root.stepSince === 0)
                root.stepSince = Date.now();
            let ok = false;
            try { ok = s.until(); } catch (err) { ok = false; }
            const late = Date.now() - root.stepSince > s.budget;
            if (!ok && !late)
                return;
            tick.stop();
            try {
                if (!ok)
                    root.check(s.name + " (waited " + s.budget + " ms)", false, "its condition never held");
                else
                    s.then();
            } catch (err) {
                root.check(s.name, false, "threw: " + err);
            }
            root.at++;
            root.stepSince = 0;
            tick.start();
        }
    }

    // saved between steps
    property var recRm: null
    property var recPx: null
    property var recT: null
    property int rowSerial0: 0

    Component.onCompleted: {
        if (root.work === "") { quit.start(); return; }       // smoked bare: nothing to drive
        root.stubBus();
        root.stubOsd();
        const w = root.work;

        // ===== (pure) the parser and the words, beside the service ==============================================================
        root.step("start", () => true, () => {
            const odd = ["", "   ", "x", "[1]", "null", "{", "{\"v\":2}", "{\"v\":1,\"error\":\"boom\"}", "{\"v\":1,\"devices\":\"no\",\"jobs\":7}", undefined, null, 5];
            let threw = false, shapes = true;
            for (const t of odd) {
                try { const r = Model.parseLine(t); if (typeof r.ok !== "boolean") shapes = false; } catch (e) { threw = true; }
            }
            root.check("parser: total, never throws", !threw && shapes);
            const r = Model.parseLine("{\"v\":1,\"serial\":2,\"devices\":[{\"key\":\"adb:X\"},{\"key\":\"adb:X\"}],\"jobs\":[{\"id\":\"a\"}]}");
            const d = r.line.devices[0];
            root.check("parser: every optional field has its neutral value, a duplicate key is dropped",
                       r.ok && r.line.devices.length === 1 && d.name === "adb:X" && d.kdc === null && d.skin === "generic" && Object.keys(d.can).length === Model.ACTIONS.length && d.pin === "none"
                       && d.can.mirror.why === "" && d.mounts.usb.state === "unmounted" && r.line.jobs[0].ended === null && r.line.jobs[0].total === 0
                       && r.line.env.have.scrcpy === "", JSON.stringify(d).slice(0, 200));
            root.check("parser: the tool's own error line is an error, not a state", Model.parseLine("{\"v\":1,\"error\":\"boom\"}").ok === false
                       && /boom/.test(Model.parseLine("{\"v\":1,\"error\":\"boom\"}").error));
            const d1 = Model.diffKeys(["a", "b", "c"], ["c", "a", "d"]);
            root.check("diffKeys", j(d1) === j({ added: ["d"], removed: ["b"], reordered: true, changed: true }) && !Model.diffKeys(["a"], ["a"]).changed, j(d1));
            root.check("words are the line's facts", Model.linkWords({ link: "both" }) === "On the cable and Wi-Fi" && Model.linkWords({ link: "none" }) === "Not in reach"
                       && Model.bytesWords(12058624) === "11.5 MiB" && Model.sendBody(root.sendJob("x")) === "3 files, 11.5 MiB");
        });

        // ===== (a) not live: scenario lines through the parser, actions in `calls`, nothing runs ===============================
        root.step("a: make", () => true, () => {
            root.svcM = svcComp.createObject(root, { scenario: "wired", mockLineMs: 30, mockStepMs: 40, toolPath: w + "/a/lares-bridge" });
        });
        root.step("a: ready", () => root.svcM && root.svcM.ready, () => {
            const m = root.svcM;
            const d = m.current;
            root.check("a: a scenario's line arrives through the real parser", m.serial === 1 && m.count === 2 && d && d.name === "REDMAGIC 10S Pro" && d.link === "usb"
                       && d.skin === "redmagic-10s-pro-moonlight" && d.battery.charge === 81 && d.can.mirror.ok && m.currentKey === root.rm && m.env.adbServer === "up",
                       JSON.stringify([m.serial, m.count, m.currentKey]));
            root.check("a: no Process of any kind exists, and nothing ran", root.procs(m) === 0 && root.events_("a").length === 0, "procs=" + root.procs(m));
            m.mirror(root.rm, { mode: "desktop" });
            const c = m.calls[m.calls.length - 1];
            root.check("a: an action is appended to `calls` and answers a turn later (busy first)", c.action === "mirror" && c.key === root.rm && c.args.mode === "desktop"
                       && c.args.screenOff === false && m.acts.mirror.state === "busy", JSON.stringify([c, m.acts.mirror]));
            root.check("a: a second ask of the same action is refused while it is out", m.mirror(root.rm, {}) === false);
        });
        root.step("a: mirror reacted", () => root.svcM.job(root.rm, "mirror") !== null && root.svcM.acts.mirror.state === "done", () => {
            const m = root.svcM;
            const jb = m.job(root.rm, "mirror");
            root.check("a: `react` put a mirror job on the line and the act is done, once told", jb.mode === "desktop" && jb.via === "usb" && m.serial >= 2
                       && root.actedM.filter(a => a[1] === "mirror").length === 1 && root.actedM[0][2] === true, JSON.stringify([jb, root.actedM]));
            root.check("a: the state line says what runs", Model.stateLine(m.current, m.jobs) === "Desktop mode over USB", Model.stateLine(m.current, m.jobs));
            m.stopJob(jb.id);
        });
        root.step("a: stopped and acknowledged", () => root.svcM.jobs.length === 0 && root.svcM.calls.some(c => c.action === "ack"), () => {
            root.check("a: stop ends the job, the shell acknowledges it, the tool forgets it", root.svcM.calls.filter(c => c.action === "ack").length === 1
                       && root.svcM.job(root.rm, "mirror") === null, JSON.stringify(root.svcM.calls.map(c => c.action)));
            root.svcM.mount(root.rm, "usb");
        });
        root.step("a: mounted", () => root.svcM.current && root.svcM.current.mounts.usb.state === "mounted", () => {
            root.check("a: mount moved the state", Model.stateLine(root.svcM.current, root.svcM.jobs) === "Storage mounted", Model.stateLine(root.svcM.current, root.svcM.jobs));
            root.resetToasts();
            root.svcM.send(root.rm, ["/a/one.png", "/a/two.png"]);
        });
        root.step("a: send runs", () => root.svcM.busy, () => {
            root.check("a: busy while a send runs", root.svcM.busy === true && root.svcM.job(root.rm, "send") !== null);
        });
        root.step("a: send done", () => !root.svcM.busy && root.svcM.jobs.filter(x => x.kind === "send").length === 0 && root.posts.some(p => /^sent-/.test(p.key)), () => {
            const cl = root.posts.filter(p => /^sent-/.test(p.key));
            root.check("a: the mock's send steps to its end: one closing toast", cl.length === 1 && cl[0].title === "2 files sent to REDMAGIC 10S Pro", JSON.stringify(root.posts.map(p => [p.key, p.title])));
            root.svcM.scenario = "asleep";
        });
        root.step("a: asleep", () => root.svcM.scenario === "asleep" && root.svcM.current && root.svcM.current.present === false, () => {
            root.svcM.ring(root.rm);
        });
        root.step("a: the mock answers by the tool's own words", () => root.svcM.acts.ring.state === "failed", () => {
            const a = root.svcM.acts.ring;
            root.check("a: an action the device cannot do fails with `can.<x>.why`", a.why === "Out of reach" && a.hint !== ""
                       && root.actedM.filter(x => x[1] === "ring").length === 1 && root.actedM[root.actedM.length - 1][2] === false, JSON.stringify(a));
            // every scenario, all lines at once
            root.svcM.mockLineMs = 0;
            const names = Scenarios.names();
            let all = true, why = "";
            for (const n of names) {
                const before = root.svcM.serial;
                root.svcM.scenario = "";
                root.svcM.scenario = n;
                const lines = Scenarios.lines(n).length;
                const good = n === "error" ? lines - 1 : lines;
                let canAll = true;
                for (let i = 0; i < root.svcM.count; i++)
                    if (Object.keys(root.svcM.devices.get(i).rec.d.can).length !== Model.ACTIONS.length)
                        canAll = false;
                if (root.svcM.serial - before !== good || !canAll || (n === "none" && (root.svcM.count !== 0 || root.svcM.current !== null))
                        || (n === "error" && (root.svcM.lastError === "" || root.svcM.count !== 2 || root.svcM.jobs.length !== 1))) {
                    all = false;
                    why += n + " (+" + (root.svcM.serial - before) + " of " + good + ", count " + root.svcM.count + ", err '" + root.svcM.lastError + "') ";
                }
            }
            root.check("a: every scenario parses through the real parser; the error line is refused and changes nothing", all, why);
            root.check("a: still no Process, still nothing run", root.procs(root.svcM) === 0 && root.events_("a").length === 0);
        });

        // ===== (b) live on the stub: rows, serial, the line's order ================================================================
        root.step("b: feed one", () => true, () => { root.feed("b", root.lineOf(1)); });
        root.step("b: make", () => !root.feedBusy && root.feedQ.length === 0, () => {
            root.svcL = svcComp.createObject(root, { live: true, toolPath: w + "/b/lares-bridge", configPath: w + "/b/cfg/bridge.jsonc",
                pickerPath: w + "/b/pick_ok.sh", timeoutOverrideMs: 900 });
        });
        root.step("b: ready", () => root.svcL && root.svcL.ready, () => {
            const l = root.svcL;
            root.recRm = l.devices.get(0).rec;
            root.recPx = l.devices.get(1).rec;
            root.check("b: live: the first line of the stub", l.serial === 1 && l.count === 2 && l.current.name === "REDMAGIC 10S Pro" && l.rowSerial === 1, JSON.stringify([l.serial, l.count, l.rowSerial]));
            root.check("b: live: the watcher is the one Process (positive control of the walker)", root.procs(l) >= 1, "procs=" + root.procs(l));
            const log = root.events_("b").filter(e => e.ev === "watch");
            root.check("b: `watch` runs once, unbuffered", log.length === 1 && log[0].argv.length === 1, JSON.stringify(log));
            root.rowSerial0 = l.rowSerial;
            root.feed("b", root.lineOf(2, x => { x.devices[0].battery.charge = 79; }));
        });
        root.step("b: line 2", () => root.svcL.serial === 2, () => {
            const l = root.svcL;
            root.check("b: the rows are the same `rec` objects, `d` re-assigned", l.devices.get(0).rec === root.recRm && l.devices.get(1).rec === root.recPx
                       && root.recRm.d.battery.charge === 79 && l.current === root.recRm.d && l.rowSerial === root.rowSerial0, root.recRm.d.battery.charge + " " + l.rowSerial);
            // an added device in front and a new order
            root.feed("b", root.lineOf(3, x => { x.devices = [root.tablet(), x.devices[1], x.devices[0]]; x.devices[2].battery.charge = 79; }));
        });
        root.step("b: line 3", () => root.svcL.serial === 3, () => {
            const l = root.svcL;
            root.recT = l.devices.get(0).rec;
            root.check("b: an added and a reordered device: kept rows keep their `rec`", l.count === 3 && l.devices.get(0).key === "adb:T1" && l.devices.get(1).rec === root.recPx
                       && l.devices.get(2).rec === root.recRm && l.rowSerial > root.rowSerial0 && l.devices.get(0).rec.d.name === "Tab S9", JSON.stringify([l.count, l.rowSerial]));
            root.rowSerial0 = l.rowSerial;
            root.feed("b", root.lineOf(4, x => { x.devices = [root.tablet(), x.devices[0]]; x.devices[1].battery.charge = 79; }));
        });
        root.step("b: line 4", () => root.svcL.serial === 4, () => {
            const l = root.svcL;
            root.check("b: a removed device leaves the model and the lookup", l.count === 2 && l.device(root.px) === null && l.devices.get(1).rec === root.recRm && l.rowSerial > root.rowSerial0
                       && l.device(root.rm) !== null && l.device("adb:T1").name === "Tab S9");
            root.snaps = [];
            // ONE line that changes devices, jobs, pairing and env together
            root.feed("b", root.lineOf(5, x => {
                x.devices = [root.tablet(), x.devices[0], { key: "adb:N2", name: "Other", type: "tablet", present: true, link: "usb" }];
                x.devices[1].battery.charge = 79;
                x.jobs = [{ id: "m-18", kind: "mirror", device: root.rm, mode: "mirror", via: "usb", phase: "running", started: 100 }];
                x.pairing = [{ key: "kdc:new", name: "New phone", type: "phone", byPeer: true, verificationKey: "AB12CD34" }];
                x.env.kdeconnect = "down";
            }));
        });
        root.step("b: line 5", () => root.svcL.serial === 5, () => {
            const s = root.snaps[root.snaps.length - 1];
            root.check("b: serial is written last (a handler on serialChanged sees the new devices, jobs, pairing and env)",
                       root.snaps.length === 1 && s.serial === 5 && s.count === 3 && s.jobs === 1 && s.pairing === 1 && s.kdc === "down", JSON.stringify(root.snaps));
            root.check("b: `job(key, kind)` finds the live job; busy is only for a send", root.svcL.job(root.rm, "mirror").id === "m-18" && root.svcL.job(root.rm, "send") === null && root.svcL.busy === false);
            root.errors = [];
        });

        // ===== (f) garbage and an error line ===================================================================================
        root.step("f: feed garbage", () => true, () => {
            root.feed("b", "this is not json {{");
            root.feed("b", "{\"v\":1,\"error\":\"boom\"}");
            root.feed("b", "[1,2,3]");
            root.feed("b", "{\"v\":2}");
            root.feed("b", "");
            // the sentinel: a good line after them, the same state with a new battery
            root.feed("b", root.lineOf(6, x => {
                x.devices = [root.tablet(), x.devices[0], { key: "adb:N2", name: "Other", type: "tablet", present: true, link: "usb" }];
                x.devices[1].battery.charge = 78;
                x.jobs = [{ id: "m-18", kind: "mirror", device: root.rm, mode: "mirror", via: "usb", phase: "running", started: 100 }];
                x.pairing = [{ key: "kdc:new", name: "New phone", type: "phone", byPeer: true, verificationKey: "AB12CD34" }];
                x.env.kdeconnect = "down";
            }));
        });
        root.step("f: sentinel", () => root.svcL.serial >= 6, () => {
            const l = root.svcL;
            root.check("f: a garbage line and an error line change nothing, and are counted nowhere", l.serial === 6 && l.count === 3 && l.devices.get(0).key === "adb:T1" && l.jobs.length === 1,
                       JSON.stringify([l.serial, l.count]));
            root.check("f: each is said once as lastError, and the next good line clears it", root.errors.length >= 5 && /not JSON/.test(root.errors[0]) && /boom/.test(root.errors[1])
                       && /not an object/.test(root.errors[2]) && /version 2/.test(root.errors[3]) && l.lastError === "", JSON.stringify(root.errors));
        });

        // ===== (c) every action's argv; a failed one-shot; one at a time per device ============================================
        root.step("c: ask everything", () => true, () => {
            const l = root.svcL;
            root.actedL = [];
            root.resetToasts();
            const r = [];
            r.push(l.mirror(root.rm, { mode: "desktop", screenOff: true, record: true }));
            r.push(l.stopJob("m-18"));
            r.push(l.mount(root.rm, "usb"));
            r.push(l.unmount(root.rm, "wifi"));
            r.push(l.shot(root.rm));
            r.push(l.pressKey(root.rm, "volup"));
            r.push(l.pair(root.rm));
            r.push(l.accept(root.rm));
            r.push(l.reject(root.rm));
            r.push(l.arm(root.rm));
            r.push(l.refresh());
            r.push(l.setPref(root.rm, "mode", "desktop"));
            r.push(l.setPref(root.rm, "keepWireless", true));
            r.push(l.loadFacts(root.rm));
            r.push(l.send(root.rm, ["/a/b.png", "/c d/e.txt"]));
            r.push(l.select("adb:T1"));
            root.check("c: every well-formed request is taken", r.every(x => x === true), JSON.stringify(r));
            root.check("c: a malformed request is refused and asks nothing", l.pressKey(root.rm, "home") === false && l.mount(root.rm, "nfs") === false
                       && l.setPref(root.rm, "mode", "nope") === false && l.send(root.rm, ["relative", "-x"]) === false && l.stopJob("") === false);
        });
        root.step("c: answered", () => root.ended("b").length >= 17 && root.actedL.some(a => a[1] === "select") && root.actedL.some(a => a[1] === "refresh"), () => {
            const want = [
                ["mirror", root.rm, "--mode", "desktop", "--screen-off", "--record"], ["stop", "m-18"], ["mount", root.rm, "usb"], ["unmount", root.rm, "wifi"],
                ["shot", root.rm], ["key", root.rm, "volup"], ["pair", root.rm], ["accept", root.rm], ["reject", root.rm], ["arm", root.rm],
                ["refresh"], ["set", root.rm, "mode", "\"desktop\""], ["set", root.rm, "keepWireless", "true"], ["facts", root.rm],
                ["send", root.rm, "/a/b.png", "/c d/e.txt"], ["select", "adb:T1"],
                // the start's sweep of holds a crash left (no cast runs at a start)
                ["castend", "--all"]
            ];
            const got = root.ended("b").map(a => root.j(a)).sort();
            const exp = want.map(a => root.j(a)).sort();
            root.check("c: every action makes the contract's argv", root.j(got) === root.j(exp), "\n  got " + root.j(got) + "\n  exp " + root.j(exp));
            root.check("c: accept and reject are answered to the pairing, not to the current device's acts", root.actedL.filter(a => a[1] === "accept").length === 1
                       && root.actedL.filter(a => a[1] === "reject").length === 1, root.j(root.actedL.map(a => a[1])));
            const mine = root.ended("b").filter(a => a[1] === root.rm).map(a => a[0]);
            root.check("c: one device's calls run in the order they were asked", mine.indexOf("mirror") < mine.indexOf("mount") && mine.indexOf("mount") < mine.indexOf("shot")
                       && mine.indexOf("shot") < mine.indexOf("send"), JSON.stringify(mine));
            const l = root.svcL;
            root.check("c: a failed one-shot: failed with the tool's reason, hint and ONE `acted`", l.acts.mountUsb.state === "failed" && l.acts.mountUsb.why === "aft-mtp-mount: no MTP device"
                       && l.acts.mountUsb.hint === "Set USB to File transfer" && root.actedL.filter(a => a[1] === "mountUsb").length === 1 && root.actedL.filter(a => a[1] === "mountUsb")[0][2] === false,
                       JSON.stringify([l.acts.mountUsb, root.actedL.filter(a => a[1] === "mountUsb")]));
            root.check("c: an answer that is not JSON is a stated failure", l.acts.mountUsb.at > 1e12 && root.actedL.some(a => a[1] === "refresh" && a[2] === false && /not JSON/.test(a[3])), JSON.stringify(root.actedL.filter(a => a[1] === "refresh")));
            root.check("c: a mount that failed with the popup closed is ONE toast, with reason and hint", root.postsOf("fail-" + root.rm + "-mountUsb").length === 1
                       && /no MTP device/.test(root.postsOf("fail-" + root.rm + "-mountUsb")[0].body) && /File transfer/.test(root.postsOf("fail-" + root.rm + "-mountUsb")[0].body)
                       && /^Could not mount/.test(root.postsOf("fail-" + root.rm + "-mountUsb")[0].title), JSON.stringify(root.posts.map(p => [p.key, p.title])));
            root.check("c: a shot goes to the OSD's capture card, not a toast", root.osdReqs.length === 1 && root.osdReqs[0].kind === "capture" && root.osdReqs[0].capture.what === "shot"
                       && root.osdReqs[0].capture.path === "/tmp/bsp-shot.png" && root.osdReqs[0].capture.thumb === "file:///tmp/bsp-shot.png" && root.postsOf("shot-" + root.rm).length === 0,
                       JSON.stringify(root.osdReqs));
            root.osdUp = false;
            root.svcL.shot(root.rm);
        });
        root.step("c: shot without an OSD", () => root.postsOf("shot-" + root.rm).length === 1, () => {
            root.check("c: no OSD: one toast with the path", root.postsOf("shot-" + root.rm)[0].body === "/tmp/bsp-shot.png" && root.osdReqs.length === 2);
            root.osdUp = true;
            // the lane: clip is slow, ring (which fails) is asked behind it
            root.actedL = [];
            const l = root.svcL;
            root.check("c: clip, then ring", l.clip(root.rm) === true && l.ring(root.rm) === true && l.acts.clip.state === "busy", JSON.stringify(l.acts.clip));
            root.check("c: the same action is refused while it is out", l.clip(root.rm) === false);
        });
        root.step("c: clip and ring answered", () => root.svcL.acts.clip.state === "done" && root.svcL.acts.ring.state === "failed", () => {
            const ev = root.events_("b");
            const clipEnd = ev.filter(e => e.ev === "end" && e.argv[0] === "clip")[0];
            const ringStart = ev.filter(e => e.ev === "start" && e.argv[0] === "ring")[0];
            root.check("c: one at a time per device: ring starts after clip has answered", clipEnd && ringStart && ringStart.t >= clipEnd.t, root.j([clipEnd && clipEnd.t, ringStart && ringStart.t]));
            const a = root.svcL.acts.ring;
            root.check("c: failed ring: the reason, and exactly one `acted` for it", a.state === "failed" && a.why === "the phone is not on KDE Connect" && a.hint === "Open KDE Connect on the phone"
                       && root.actedL.filter(x => x[1] === "ring").length === 1 && root.actedL.filter(x => x[1] === "clip").length === 1, root.j(root.actedL));
            root.check("c: no toast for a failed ring", root.postsOf("fail-" + root.rm + "-ring").length === 0);
            // a settled act goes idle when its `can` changes
            root.feed("b", root.lineOf(7, x => { x.devices = [root.tablet(), x.devices[0]]; x.devices[1].can.ring = { ok: true, why: "", hint: "", via: "" }; x.devices[1].battery.charge = 78; }));
        });
        root.step("c: can changed", () => root.svcL.serial === 7, () => {
            root.check("c: an act goes idle when its `can` changes (and only that one)", root.svcL.acts.ring.state === "idle" && root.svcL.acts.clip.state === "done", root.j([root.svcL.acts.ring, root.svcL.acts.clip]));
            // and when the device changes
            root.feed("b", root.lineOf(8, x => { x.devices = [root.tablet(), x.devices[0]]; x.devices[1].can.ring = { ok: true, why: "", hint: "", via: "" }; x.current = "adb:T1"; }));
        });
        root.step("c: device changed", () => root.svcL.serial === 8, () => {
            root.check("c: every act is idle for another current device", root.svcL.currentKey === "adb:T1" && Object.keys(root.svcL.acts).every(k => root.svcL.acts[k].state === "idle")
                       && Object.keys(root.svcL.acts).length === Model.ACTIONS.length, root.j(root.svcL.acts));
            root.feed("b", root.lineOf(9, x => { x.devices = [root.tablet(), x.devices[0]]; x.devices[1].can.ring = { ok: true, why: "", hint: "", via: "" }; x.current = root.rm; }));
        });
        root.step("c: back on the phone; a one-shot that never answers", () => root.svcL.serial === 9, () => {
            root.actedL = [];
            root.svcL.disarm(root.rm);
        });
        root.step("c: disarm answered", () => root.actedL.some(a => a[1] === "arm"), () => {
            root.check("c: disarm is the tool's `disarm`, tracked as the arm act", root.endedOf("b", "disarm").length === 1 && root.j(root.endedOf("b", "disarm")[0]) === root.j(["disarm", root.rm])
                       && root.svcL.acts.arm.state === "done", root.j(root.svcL.acts.arm));
            root.actedL = [];
            root.svcL.unpair(root.rm);
        });
        root.step("c: timed out", () => root.svcL.acts.unpair.state === "failed", () => {
            root.check("c: a one-shot past its deadline is `timed out`, once", root.svcL.acts.unpair.why === "timed out" && root.actedL.filter(a => a[1] === "unpair").length === 1
                       && root.actedL.filter(a => a[1] === "unpair")[0][3] === "timed out" && root.events_("b").some(e => e.ev === "start" && e.argv[0] === "unpair" && e.argv[1] === root.rm), root.j(root.actedL));
        }, 12000);

        // ===== (d) a send: one live toast, then one closing toast in the turn the progress goes ================================
        root.step("d: start", () => true, () => {
            root.resetToasts();
            root.feed("b", root.lineOf(10, x => { x.devices = [x.devices[0]]; x.jobs = [root.sendJob("s-1", { phase: "starting" })]; }));
        });
        root.step("d: progress", () => root.postsOf("send-s-1").length === 1, () => {
            const p = root.postsOf("send-s-1")[0];
            root.check("d: one live progress toast, plain totals before anything moved", p.live === true && p.timeoutMs === -1 && p.title === "Sending to REDMAGIC 10S Pro"
                       && p.body === "3 files, 11.5 MiB" && !/0 \//.test(p.body), root.j(p));
            root.check("d: busy while the send runs", root.svcL.busy === true && Model.stateLine(root.svcL.current, root.svcL.jobs) === "Sending 3 files");
            root.feed("b", root.lineOf(11, x => { x.devices = [x.devices[0]]; x.jobs = [root.sendJob("s-1", { file: 2, done: 4812800, rate: 2411724 })]; }));
        });
        root.step("d: progress moved", () => root.postsOf("send-s-1").length === 2, () => {
            const p = root.postsOf("send-s-1")[1];
            root.check("d: the figures update the same toast in place (same key, live)", p.live === true && p.body === "File 2 of 3 · 4.6 MiB of 11.5 MiB · 2.3 MiB/s" && root.postsOf("sent-s-1").length === 0, p.body);
            root.feed("b", root.lineOf(12, x => { x.devices = [x.devices[0]]; x.jobs = [root.sendJob("s-1", { phase: "done", file: 3, done: 12058624, ended: 130, code: 0 })]; }));
        });
        root.step("d: ended", () => root.postsOf("sent-s-1").length >= 1 && root.endedOf("b", "ack").length >= 1, () => {
            // the same ended job is carried by the next lines, until the tool has heard the ack
            root.feed("b", root.lineOf(13, x => { x.devices = [x.devices[0]]; x.jobs = [root.sendJob("s-1", { phase: "done", file: 3, done: 12058624, ended: 130, code: 0 })]; }));
        });
        root.step("d: carried again", () => root.svcL.serial === 13, () => {
            const ci = root.events.indexOf("post sent-s-1");
            root.check("d: the closing toast takes the progress toast's place (posted, then the progress withdrawn)", ci >= 0 && root.events[ci + 1] === "withdraw send-s-1", root.j(root.events));
            root.check("d: the progress toast goes with the closing toast (post, then withdraw)", ci >= 0 && root.events[ci + 1] === "withdraw send-s-1" && root.withdrawn.indexOf("send-s-1") >= 0, root.j(root.events));
            const cl = root.postsOf("sent-s-1");
            const acks = root.endedOf("b", "ack").filter(a => a[1] === "s-1");
            root.check("d: exactly one closing toast and one ack per job", cl.length === 1 && acks.length === 1 && cl[0].title === "3 files sent to REDMAGIC 10S Pro" && cl[0].body === "11.5 MiB", root.j([cl.length, acks.length, cl[0] && cl[0].title]));
            root.check("d: not busy once it ended", root.svcL.busy === false);
            root.feed("b", root.lineOf(14, x => { x.devices = [x.devices[0]]; }));
        });
        root.step("d: popup open", () => root.svcL.serial === 14, () => {
            // the popup is open and shows the transfer: no progress toast, but the closing one is posted
            root.resetToasts();
            root.svcL.popupOpen = true;
            root.feed("b", root.lineOf(15, x => { x.devices = [x.devices[0]]; x.jobs = [root.sendJob("s-2", { phase: "running", file: 1, done: 1000000 })]; }));
        });
        root.step("d: popup open, running", () => root.svcL.serial === 15, () => {
            root.check("d: nothing while the popup is open and shows the same fact", root.posts.length === 0, root.j(root.posts.map(p => p.key)));
            root.feed("b", root.lineOf(16, x => { x.devices = [x.devices[0]]; x.jobs = [root.sendJob("s-2", { phase: "failed", file: 1, done: 1000000, ended: 140, code: 1, reason: "adb: error: device offline" })]; x.devices[0].can.send = { ok: false, why: "adb is not connected", hint: "Reconnect the cable", via: "" }; }));
        });
        root.step("d: failed with the popup open", () => root.postsOf("sent-s-2").length === 1, () => {
            const p = root.postsOf("sent-s-2")[0];
            root.check("d: the closing toast of a send is posted even with the popup open: the tool's reason and hint", p.title === "Could not send to REDMAGIC 10S Pro"
                       && p.body === "adb: error: device offline\nReconnect the cable" && root.withdrawn.length === 0, root.j(p));
            // a send that runs while the popup is open gets its progress toast when the popup closes
            root.feed("b", root.lineOf(17, x => { x.devices = [x.devices[0]]; x.jobs = [root.sendJob("s-3", { phase: "running", file: 1, done: 2000000 })]; }));
        });
        root.step("d: s-3 running, popup open", () => root.svcL.serial === 17 && root.endedOf("b", "ack").filter(a => a[1] === "s-2").length === 1, () => {
            root.check("d: no progress toast under the open popup", root.postsOf("send-s-3").length === 0);
            root.svcL.popupOpen = false;
        });
        root.step("d: popup closed", () => root.postsOf("send-s-3").length === 1, () => {
            root.check("d: the popup closing tells the running send", root.postsOf("send-s-3")[0].live === true);
            root.svcL.popupOpen = true;
        });
        root.step("d: popup open again", () => root.withdrawn.indexOf("send-s-3") >= 0, () => {
            root.check("d: the popup opening takes the progress toast away", true);
            root.feed("b", root.lineOf(18, x => { x.devices = [x.devices[0]]; }));
        });

        // ===== (e) jobs that ended while no shell ran ============================================================================
        root.step("e: feed", () => root.svcL.serial === 18, () => {
            root.svcL.popupOpen = false;
            root.resetToasts();
            root.feed("e", root.lineOf(1, x => {
                x.devices = [x.devices[0]];
                x.devices[0].can.send = { ok: false, why: "x", hint: "Plug the phone in", via: "" };
                x.jobs = [
                    root.sendJob("s-9", { phase: "failed", ended: 90, code: 1, reason: "adb: error: no devices/emulators found" }),
                    { id: "m-9", kind: "mirror", device: root.rm, mode: "mirror", via: "usb", phase: "done", started: 10, ended: 80, code: 0 },
                    { id: "k-9", kind: "mount", device: root.rm, mode: "", via: "mtp", phase: "failed", started: 10, ended: 80, code: 1, reason: "fusermount3: mount point busy" },
                    root.sendJob("s-8", { phase: "done", files: 1, file: 1, done: 5000, total: 5000, ended: 70, code: 0 })
                ];
            }));
        });
        root.step("e: make", () => !root.feedBusy && root.feedQ.length === 0, () => {
            root.svcE = svcComp.createObject(root, { live: true, toolPath: w + "/e/lares-bridge", configPath: w + "/e/none.jsonc", timeoutOverrideMs: 900 });
        });
        root.step("e: told and acknowledged", () => root.svcE && root.svcE.ready && root.endedOf("e", "ack").length >= 4, () => {
            const acks = root.endedOf("e", "ack").map(a => a[1]).sort();
            root.check("e: every ended job of the first line is acknowledged once, told or not", root.j(acks) === root.j(["k-9", "m-9", "s-8", "s-9"]), root.j(acks));
            const s9 = root.postsOf("sent-s-9"), s8 = root.postsOf("sent-s-8"), k9 = root.postsOf("fail-k-9");
            root.check("e: a send that failed while no shell ran: its closing toast with the tool's reason and hint", s9.length === 1 && s9[0].title === "Could not send to REDMAGIC 10S Pro"
                       && s9[0].body === "adb: error: no devices/emulators found\nPlug the phone in", root.j(s9));
            root.check("e: a send that finished while no shell ran: its closing toast", s8.length === 1 && s8[0].title === "1 file sent to REDMAGIC 10S Pro", root.j(s8));
            root.check("e: a mount that failed: one toast; a mirror that ended by itself: none", k9.length === 1 && /mount point busy/.test(k9[0].body) && root.postsOf("fail-m-9").length === 0
                       && root.posts.length === 3, root.j(root.posts.map(p => p.key)));
            root.check("e: nothing in `busy`", root.svcE.busy === false);
        });

        // ===== the rest of the service: files, clipboard, picker, facts at the popup's open ==================================
        root.step("x: openFiles, copyText", () => true, () => {
            const l = root.svcL;
            const before = cmdRunner.calls.length;
            // the runner here is not live: a record; the config's argv with {path} replaced, detached
            const ok = l.openFiles(root.rm, "usb");
            const rec = cmdRunner.calls[cmdRunner.calls.length - 1];
            root.check("x: openFiles runs `files.open` with {path} replaced, detached (the user's config, read hot)", ok && cmdRunner.calls.length === before + 1 && rec.detached === true
                       && root.j(rec.argv) === root.j(["echo", "open", "/mnt/android"]) && l.settings.files.open[0] === "echo", root.j(rec));
            root.check("x: openFiles refuses a mount that is not usb|wifi", l.openFiles(root.rm, "nfs") === false);
            l.copyText("/mnt/android/DCIM");
            root.check("x: copyText goes to the clipboard service as a copy", clipStub.pastes.length === 1 && clipStub.pastes[0].opts.mode === "copy" && clipStub.pastes[0].opts.text === "/mnt/android/DCIM"
                       && clipStub.pastes[0].keys.length === 0, root.j(clipStub.pastes));
            root.actedL = [];
            l.pickAndSend(root.rm);
        });
        root.step("x: picker sends", () => root.endedOf("b", "send").filter(a => a[2] === "/p/a.png").length === 1, () => {
            const a = root.endedOf("b", "send").filter(x => x[2] === "/p/a.png")[0];
            root.check("x: the portal's NUL-separated picks go to `send`", root.j(a) === root.j(["send", root.rm, "/p/a.png", "/p/b c.txt"]) && root.svcL.picking === false, root.j(a));
            const pk = root.svcL.calls.filter(c => c.action === "pickAndSend");
            const pargv = pk.length > 0 ? pk[pk.length - 1].args.argv : [];
            root.check("x: bridge.jsonc files.pickDir: the chooser starts in it (~ is the home)", pargv.indexOf((Quickshell.env("HOME") || "") + "/Inbox") >= 0, root.j(pargv));
            root.svcL.pickerPath = root.work + "/b/pick_cancel.sh";
            root.svcL.pickAndSend(root.rm);
        });
        root.step("x: picker cancelled", () => root.svcL.picking === false && root.svcL.pickerPath.indexOf("pick_cancel") > 0, () => {
            const n = root.endedOf("b", "send").filter(x => x[2] === "/p/a.png").length;
            root.check("x: a cancelled dialog sends nothing", n === 1, "sends " + n);
            root.svcL.pickerPath = root.work + "/b/pick_fail.sh";
            root.svcL.pickAndSend(root.rm);
        });
        root.step("x: picker failed", () => root.svcL.acts.send.state === "failed", () => {
            root.check("x: a picker that fails is the send's failure, said once", /file picker failed/.test(root.svcL.acts.send.why) && root.actedL.filter(a => a[1] === "send" && a[2] === false).length === 1, root.j(root.svcL.acts.send));
            // facts at the popup's open: once, when can.facts.ok
            root.svcL.popupOpen = false;
        });
        root.step("x: facts at the open", () => root.svcL.acts.facts.state !== "busy", () => {
            const before = root.endedOf("b", "facts").length;
            root.factsBefore = before;
            root.svcL.popupOpen = true;
        });
        root.step("x: facts asked", () => root.endedOf("b", "facts").length === root.factsBefore + 1, () => {
            root.check("x: the popup opening reads the current device's facts, once", root.endedOf("b", "facts").length === root.factsBefore + 1
                       && root.endedOf("b", "facts")[root.factsBefore][1] === root.rm);
            root.svcL.popupOpen = false;
            root.feed("b", root.lineOf(19, x => { x.devices = [x.devices[0]]; x.devices[0].can.facts = { ok: false, why: "adb is not connected", hint: "x", via: "" }; }));
        });
        root.step("x: facts not allowed", () => root.svcL.serial === 19, () => {
            root.svcL.popupOpen = true;
            root.tmark = Date.now();
        });
        root.step("x: no facts when it cannot", () => Date.now() - root.tmark > 500, () => {
            root.check("x: nothing asked at the open when `can.facts` says no", root.endedOf("b", "facts").length === root.factsBefore + 1);
            // ---- (u) the unlock: never at a popup's open, even with a PIN kept (only a cast lights the phone); the PIN only on stdin
            root.svcL.popupOpen = false;
            root.unlocksBefore = root.endedOf("b", "unlock").length;
            root.feed("b", root.lineOf(20, x => { x.devices = [x.devices[0]]; x.devices[0].pin = "set"; x.devices[0].can.unlock = { ok: true, why: "", hint: "", via: "usb" }; }));
        });
        root.step("u: a PIN kept", () => root.svcL.serial === 20, () => {
            root.svcL.popupOpen = true;
            root.tmark = Date.now();
        });
        root.step("u: no unlock at the open", () => Date.now() - root.tmark > 1200, () => {
            const u = root.endedOf("b", "unlock");
            root.check("u1: the popup opening asks no unlock though a PIN is kept (only a cast lights the phone)", u.length === root.unlocksBefore, root.j(u));
            root.svcL.popupOpen = false;
            root.feed("b", root.lineOf(21, x => { x.devices = [x.devices[0]]; x.devices[0].pin = "none"; x.devices[0].can.unlock = { ok: false, why: "No PIN kept", hint: "Set it on the Details page", via: "" }; }));
        });
        root.step("u: no PIN", () => root.svcL.serial === 21, () => {
            root.svcL.popupOpen = true;
            root.tmark = Date.now();
        });
        root.step("u: nothing without a PIN", () => Date.now() - root.tmark > 500, () => {
            root.check("u2: with no PIN kept (can.unlock says no) the open asks nothing", root.endedOf("b", "unlock").length === root.unlocksBefore);
            const bad = root.svcL.setPin(root.rm, "12") || root.svcL.setPin(root.rm, "12 34") || root.svcL.setPin(root.rm, "-1234");
            root.check("u3: a PIN that is not 4-16 digits or letters is refused before anything runs", bad === false && root.endedOf("b", "pin").length === 0);
            root.svcL.setPin(root.rm, "4321Ab");
        });
        root.step("u: pin set", () => root.endedOf("b", "pin").length === 1, () => {
            const ev = root.events_("b").filter(e => e.ev === "stdin");
            const calls = root.j(root.svcL.calls);
            const argvs = root.j(root.ended("b"));
            root.check("u4: pin set takes the PIN on stdin and nowhere else (not argv, not calls)", root.j(root.endedOf("b", "pin")[0]) === root.j(["pin", root.rm, "set"])
                       && ev.length === 1 && ev[0].data === "4321Ab\n" && calls.indexOf("4321") < 0 && argvs.indexOf("4321") < 0, root.j(ev) + " " + calls.slice(-200));
        });


        // ===== (c) the cast: reconnect, the hold, the unlock trigger, the USB, the desktop's screen =============================
        root.step("k: pure", () => true, () => {
            const D = { desktopScale: 1.0, desktopMinDp: 320, desktopMinPx: 640 };
            const a = Model.desktopScreen(330, 734, 1.25, D), b = Model.desktopScreen(1000, 600, 1, D), c = Model.desktopScreen(3000, 1000, 1, D);
            root.check("c8: the desktop's screen is laptop-sized: the rest room at 1.25 is 640x1424 at 320 dpi, a wide room 1064x640 at 171, the long side capped at 2400",
                       root.j([a.w, a.h, a.dpi]) === root.j([640, 1424, 320]) && root.j([b.w, b.h, b.dpi]) === root.j([1064, 640, 171]) && root.j([c.w, c.h, c.dpi]) === root.j([2400, 800, 128]), root.j([a, b, c]));
            const p = Model.parseConfig({ cast: { desktopScale: 9, desktopMinDp: 10, desktopMinPx: 99999 } }).cast, q = Model.parseConfig({}).cast;
            root.check("c9: the three desktop keys default to 1.0 / 320 / 640 and clamp to 3.0 / 240 / 2400",
                       root.j([q.desktopScale, q.desktopMinDp, q.desktopMinPx]) === root.j([1, 320, 640]) && root.j([p.desktopScale, p.desktopMinDp, p.desktopMinPx]) === root.j([3, 240, 2400]), root.j([q, p]));
            root.check("c10: castprep takes --unlock and --hold (and may take its time), castend --sleep / --all, usbcalm is an action with its own argv",
                       root.j(Model.argvOf("castprep", "k", { unlock: true })) === root.j(["castprep", "k", "--unlock"]) && root.j(Model.argvOf("castprep", "k", {})) === root.j(["castprep", "k"])
                       && root.j(Model.argvOf("castprep", "k", { unlock: true, hold: true })) === root.j(["castprep", "k", "--unlock", "--hold"])
                       && root.j(Model.argvOf("castend", "k", { sleep: true })) === root.j(["castend", "k", "--sleep"]) && root.j(Model.argvOf("castend", "k", {})) === root.j(["castend", "k"])
                       && root.j(Model.argvOf("castend", "", { all: true })) === root.j(["castend", "--all"]) && Model.argvOf("castend", "", {}) === null
                       && root.j(Model.argvOf("usbcalm", "k", { on: false })) === root.j(["usbcalm", "k", "off"]) && root.j(Model.argvOf("usbcalm", "k", { on: true })) === root.j(["usbcalm", "k", "on"])
                       && Model.timeoutOf("castprep") >= 30000 && Model.timeoutOf("usbcalm") >= 15000 && Model.actKey("usbcalm") === "usbcalm");
            root.svcC = svcComp.createObject(root, { live: true, toolPath: w + "/c/lares-bridge", configPath: w + "/c/none.jsonc" });
            root.feed("c", root.castDev(30));
        });
        root.step("k: line", () => root.svcC.serial === 1 && root.svcC.ready, () => {
            root.castPhases = [];
            root.check("c0: a phone with a PIN kept can be cast", root.svcC.castStart(root.rm, "mirror", false) === true);
        });
        root.step("k: live", () => root.svcC.castPhase === "live", () => {
            const cp = root.endedOf("c", "castprep"), st = root.castStarts(), ce = root.endedOf("c", "castend");
            root.check("c0b: the live service's start gives back any hold a crash left (castend --all, once)", ce.length === 1 && root.j(ce[0]) === root.j(["castend", "--all"]), root.j(ce));
            root.check("c1: a Mirror started on a phone with a PIN kept walks the transport with --unlock and --hold (the screen held on), then connects -> starts -> goes live, never reconnecting",
                       cp.length === 1 && root.j(cp[0]) === root.j(["castprep", root.rm, "--unlock", "--hold"]) && st.length === 1 && st[0].argv[0] === "CS1" && st[0].argv.indexOf("--flex") < 0
                       && root.castPhases[0] === "connecting" && root.castPhases.indexOf("reconnecting") < 0, root.j(root.castPhases) + " " + root.j(st));
            // the phone closes the stream (an adbd restart): nobody asked, so it comes back by itself
            root.cBefore = cp.length;
            root.cStarts = st.length;
            root.castPhases = [];
            root.castHolds = [];
            root.cT0 = Date.now();
            root.feed("c", "{\"event\":\"ended\",\"reason\":\"the phone closed the stream\"}", "cast.out");
        });
        root.step("k: reconnected", () => root.castStarts().length === root.cStarts + 1 && root.svcC.castPhase === "live", () => {
            const st = root.castStarts(), cp = root.endedOf("c", "castprep");
            root.check("c2: a cast that ends by itself reconnects (castprep again, WITHOUT --unlock: nobody asked, a phone locked meanwhile stays locked; then a new session after the waits 0.5, 1, 2, 4 s), says 'reconnecting' and holds 'Reconnecting', never 'starting'; live again",
                       root.castPhases.indexOf("reconnecting") >= 0 && root.castPhases.indexOf("starting") < 0 && root.castPhases[root.castPhases.length - 1] === "live"
                       && root.castHolds[0] === "Reconnecting" && root.castHolds[root.castHolds.length - 1] === "" && cp.length === root.cBefore + 1 && root.j(cp[cp.length - 1]) === root.j(["castprep", root.rm, "--hold"])
                       && root.endedOf("c", "castend").length === 1
                       && root.j(root.svcC._castBackoff) === root.j([500, 1000, 2000, 4000]), root.j(root.castPhases) + " " + root.j(root.castHolds) + " castprep " + cp.length);
            // the tries run out: every new session ends at once
            root.cBefore = cp.length;
            root.cStarts = st.length;
            root.castPhases = [];
            root.castHolds = [];
            castPlan.setText(JSON.stringify({ from: st.length + 1, mode: "ended" }));
            root.feed("c", "{\"event\":\"ended\",\"reason\":\"the phone closed the stream\"}", "cast.out");
        });
        root.step("k: spent", () => root.svcC.castPhase === "failed", () => {
            // the tries come back only after a session STAYED live 10 s (castStable): c2's reconnect went live a moment ago, so a session
            // that dies at once spends the three left (one that died a second after every start would reconnect for ever otherwise)
            root.check("c3: the four tries are shared until a session stays live 10 s: three more (castprep and a session each), then 'failed' with the reason (Try again); no hold left; 'starting' never shown in between",
                       root.endedOf("c", "castprep").length === root.cBefore + 3 && root.castStarts().length === root.cStarts + 3 && root.svcC.castReason !== "" && root.svcC.castHolding === false
                       && root.castPhases.indexOf("starting") < 0 && root.castPhases[root.castPhases.length - 1] === "failed", root.j(root.castPhases) + " " + root.svcC.castReason);
            castPlan.setText(JSON.stringify({ from: 9999, mode: "ended" }));
            root.svcC.castStop();
            root.cBefore = root.endedOf("c", "castprep").length;
            root.svcC.castStart(root.rm, "mirror", false);
        }, 30000);
        root.step("k: live again", () => root.svcC.castPhase === "live", () => {
            root.svcC.castStop();
            root.tmark = Date.now();
        });
        root.step("k: stopped", () => Date.now() - root.tmark > 1500, () => {
            root.check("c4: a cast that is stopped is not brought back", root.svcC.castPhase === "idle" && root.endedOf("c", "castprep").length === root.cBefore + 1 && root.svcC.castHolding === false);
            const ce = root.endedOf("c", "castend");
            root.check("c4b: a stopped cast gives the hold back (castend, no --sleep: the phone was awake when it began and nothing woke it); one per stop",
                       ce.length === 3 && root.j(ce[2]) === root.j(["castend", root.rm]), root.j(ce));
            root.svcC.castStart(root.rm, "mirror", false);
        });
        root.step("k: live for the unlock", () => root.svcC.castPhase === "live", () => {
            root.cBefore = root.endedOf("c", "unlock").length;
            root.castHolds = [];
            const first = root.svcC.castUnlock(root.rm), second = root.svcC.castUnlock(root.rm);
            root.check("c5: the unlock the cast page asks is `unlock --auto`, once: the picture takes no input and the hold says 'Unlocking' until the answer",
                       first === true && second === true && root.svcC.castUnlocking === true && root.svcC.castHoldWhy === "Unlocking" && root.svcC.castHolding === true);
        });
        root.step("k: unlocked", () => root.svcC.castUnlocking === false, () => {
            const u = root.endedOf("c", "unlock");
            root.check("c5b: the hold ends after the unlock's answer, not before; one ask", u.length === root.cBefore + 1 && root.j(u[u.length - 1]) === root.j(["unlock", root.rm, "--auto"])
                       && root.svcC.castHoldWhy === "" && root.castHolds.join(",") === "Unlocking,", root.j(root.castHolds));
            root.feed("c", root.castDev(31, d => { d.pin = "none"; d.can.unlock = { ok: false, why: "No PIN kept", hint: "Set it on the Details page", via: "" }; }));
        });
        root.step("k: no PIN", () => root.svcC.serial === 2, () => {
            root.cBefore = root.endedOf("c", "unlock").length;
            root.check("c6: with no PIN kept there is nothing to ask: castUnlock says no and runs nothing", root.svcC.castUnlock(root.rm) === false && root.svcC.castUnlocking === false && root.svcC.castHoldWhy === "");
            // the picture woke the phone (CastPage's wakeAsked): it goes back to sleep at the end
            root.cEnd = root.endedOf("c", "castend").length;
            root.svcC.castWoke();
            root.svcC.castStop();
            // ---- the USB at the popup's open ----
            root.cUsb = root.endedOf("c", "usbcalm").length;
            root.feed("c", root.castDev(32, d => { d.pin = "none"; d.facts.usbUnlocked = "mtp"; }));
        });
        root.step("k: usb line", () => root.svcC.serial === 3 && root.endedOf("c", "castend").length === root.cEnd + 1, () => {
            const ce = root.endedOf("c", "castend");
            root.check("c6b: a cast whose picture woke the phone puts it back to sleep at its end (castend --sleep)", root.j(ce[ce.length - 1]) === root.j(["castend", root.rm, "--sleep"]), root.j(ce));
            root.svcC.popupOpen = true;
        });
        root.step("k: usb asked", () => root.endedOf("c", "usbcalm").length === root.cUsb + 1, () => {
            root.check("c7: a popup open on a phone whose USB switches at an unlock asks usbcalm off, once", root.j(root.endedOf("c", "usbcalm")[root.cUsb]) === root.j(["usbcalm", root.rm, "off"]));
            // the answer was a failure: it is not asked again in this open, whatever lines come
            root.feed("c", root.castDev(33, d => { d.pin = "none"; d.facts.usbUnlocked = "mtp"; }));
        });
        root.step("k: usb line 2", () => root.svcC.serial === 4, () => {
            root.tmark = Date.now();
        });
        root.step("k: usb wait", () => Date.now() - root.tmark > 600, () => {
            root.check("c7b: not again in the same open, a failure included", root.endedOf("c", "usbcalm").length === root.cUsb + 1);
            root.svcC.popupOpen = false;
            // from here the phone was dark when a cast began (castprep's `asleep`): c13 wants it put back to sleep at the end
            castAnswers.setText(JSON.stringify({ castprep: { ok: true, serial: "CS1", bitRate: "8M", maxFps: 30, maxSize: 0, asleep: true }, unlock: { ok: true, _sleep: 0.5 }, usbcalm: { ok: true, usbUnlocked: "none" } }));
            root.tmark = Date.now();
        });
        root.step("k: usb reopen", () => Date.now() - root.tmark > 200, () => {
            root.svcC.popupOpen = true;
        });
        root.step("k: usb asked again", () => root.endedOf("c", "usbcalm").length === root.cUsb + 2, () => {
            root.check("c7c: the next open asks again", true);
            root.svcC.popupOpen = false;
            root.feed("c", root.castDev(34, d => { d.pin = "none"; d.facts.usbUnlocked = "mtp"; d.prefs.usbUnlockMtp = true; }));
        });
        root.step("k: usb chosen on", () => root.svcC.serial === 5, () => {
            root.svcC.popupOpen = true;
            root.tmark = Date.now();
        });
        root.step("k: usb chosen wait", () => Date.now() - root.tmark > 600, () => {
            root.check("c7d: a phone the user chose File transfer for (usbUnlockMtp) is left alone", root.endedOf("c", "usbcalm").length === root.cUsb + 2);
            root.svcC.popupOpen = false;
        });
        // ---- a desktop: its screen is laptop-sized and follows the room by a live resize, never a restart ----
        root.step("k: desktop", () => true, () => {
            root.feed("c", root.castDev(35));
        });
        root.step("k: desktop line", () => root.svcC.serial === 6, () => {
            root.svcC.castWantRoom(330, 734, 1.25);
            root.cStarts = root.castStarts().length;
            root.cBefore = root.endedOf("c", "castprep").length;
            root.svcC.castStart(root.rm, "desktop", false);
        });
        root.step("k: desktop live", () => root.svcC.castPhase === "live", () => {
            const st = root.castStarts(), a = st[st.length - 1].argv;
            root.check("c11: a Desktop cast asks for a flex display 640x1424 at 320 dpi (the room at the window's ratio, laptop-sized) and no max-size",
                       st.length === root.cStarts + 1 && a.indexOf("--new-display") >= 0 && a[a.indexOf("--new-display") + 1] === "640x1424/320" && a.indexOf("--flex") >= 0 && a.indexOf("--max-size") < 0, root.j(a));
            const cp = root.endedOf("c", "castprep");
            root.check("c11b: a Desktop cast never unlocks the phone nor holds its screen: castprep without --unlock or --hold though a PIN is kept",
                       root.svcC.current !== null && root.svcC.current.pin === "set" && cp.length === root.cBefore + 1 && root.j(cp[cp.length - 1]) === root.j(["castprep", root.rm]), root.j(cp.slice(root.cBefore)));
            root.castHolds = [];
            root.castPhases = [];
            // the popup opens while the Desktop runs: its unlock would be refused (the focus is the Desktop's display) and toasted
            root.cUnl = root.endedOf("c", "unlock").length;
            root.svcC.popupOpen = true;
            root.svcC.castWantRoom(660, 1200, 1.25);
            root.tmark = Date.now();
        });
        root.step("k: desktop resized", () => root.castIns().some(l => l.indexOf("resize") >= 0) || Date.now() - root.tmark > 3000, () => {
            root.check("c11c: a popup opening while a Desktop runs for the phone asks no unlock", root.endedOf("c", "unlock").length === root.cUnl);
            root.svcC.popupOpen = false;
            root.cEnd = root.endedOf("c", "castend").length;
            const rs = root.castIns().filter(l => l.indexOf("resize") >= 0);
            root.check("c12: a settled room change resizes the desktop's screen by the start's factor (resize 1280x2328) and restarts nothing: no new session, no hold, still live",
                       rs.length === 1 && root.j(JSON.parse(rs[0])) === root.j({ resize: { w: 1280, h: 2328 } }) && root.castStarts().length === root.cStarts + 1
                       && root.castHolds.length === 0 && root.castPhases.length === 0 && root.svcC.castPhase === "live", root.j(rs) + " " + root.j(root.castHolds) + " " + root.j(root.castPhases));
            root.svcC.castStop();
        });
        root.step("k: desktop ended", () => root.endedOf("c", "castend").length === root.cEnd + 1, () => {
            const ce = root.endedOf("c", "castend");
            root.check("c13: a cast that began on a dark phone (castprep's `asleep`) puts it back to sleep at its end", root.j(ce[ce.length - 1]) === root.j(["castend", root.rm, "--sleep"]), root.j(ce));
            // ---- bridge.jsonc: no PIN typed at a start (cast.unlock "touch"), no sleep at the end (cast.sleepAtEnd false) ----
            root.svcC.config.apply({ cast: { unlock: "touch", sleepAtEnd: false } });
            root.cBefore = root.endedOf("c", "castprep").length;
            root.svcC.castStart(root.rm, "mirror", false);
        });
        root.step("k: configured live", () => root.svcC.castPhase === "live" && root.endedOf("c", "castprep").length === root.cBefore + 1, () => {
            const cp = root.endedOf("c", "castprep");
            root.check("c14: bridge.jsonc cast.unlock \"touch\": a Mirror on a phone with a PIN kept starts without --unlock (it still holds the screen)",
                       root.svcC.current !== null && root.svcC.current.pin === "set" && root.j(cp[cp.length - 1]) === root.j(["castprep", root.rm, "--hold"]), root.j(cp[cp.length - 1]));
            root.cEnd = root.endedOf("c", "castend").length;
            root.svcC.castWoke();
            root.svcC.castStop();
        });
        root.step("k: configured end", () => root.endedOf("c", "castend").length === root.cEnd + 1, () => {
            const ce = root.endedOf("c", "castend");
            root.check("c15: bridge.jsonc cast.sleepAtEnd false: a phone the picture woke is not put back to sleep", root.j(ce[ce.length - 1]) === root.j(["castend", root.rm]), root.j(ce[ce.length - 1]));
            root.svcC.config.apply({});
        });
        // ---- a recording cast (the Mirror page's Record): the same cast, castprep names the file, lares-cast writes it ----
        root.step("k: record", () => true, () => {
            castAnswers.setText(JSON.stringify({ castprep: { ok: true, serial: "CS1", bitRate: "8M", maxFps: 30, maxSize: 0, record: "/rec/phone-20261123-101010.mp4" },
                                                 unlock: { ok: true, _sleep: 0.5 }, usbcalm: { ok: true, usbUnlocked: "none" } }));
            root.cBefore = root.endedOf("c", "castprep").length;
            root.cStarts = root.castStarts().length;
            root.cRecToast = Model.recordToast({ path: "/v/a.mp4" }) !== null && Model.recordToast({ empty: true }) === null
                && /kept in \/v\/a\.mp4\.part\.flv/.test(Model.recordToast({ error: "boom", kept: "/v/a.mp4.part.flv" }).body)
                && /3 frames skipped/.test(Model.recordToast({ path: "/v/a.mp4", dropped: 3 }).body);
            root.resetToasts();
            root.svcC.castStart(root.rm, "mirror", true);
        });
        root.step("k: record live", () => root.svcC.castPhase === "live" && root.endedOf("c", "castprep").length === root.cBefore + 1 && root.castStarts().length === root.cStarts + 1, () => {
            const cp = root.endedOf("c", "castprep"), st = root.castStarts(), a = st[st.length - 1].argv;
            root.check("c16: a recording Mirror (Record on) is the same cast: castprep --unlock --hold --record, and lares-cast --record with the file castprep named; no earlier start recorded",
                       root.j(cp[cp.length - 1]) === root.j(["castprep", root.rm, "--unlock", "--hold", "--record"]) && a.indexOf("--record") >= 0
                       && a[a.indexOf("--record") + 1] === "/rec/phone-20261123-101010.mp4" && root.svcC.castRecording === true
                       && st.slice(0, st.length - 1).every(s => s.argv.indexOf("--record") < 0), root.j(cp[cp.length - 1]) + " " + root.j(a));
            root.check("c16b: recordToast: a path is one toast, `empty` none, an error names the part kept, skipped frames are told", root.cRecToast);
            root.castHolds = [];
            root.svcC.castWantRoom(2000, 3000, 1);
            root.tmark = Date.now();
        });
        root.step("k: record no reload", () => Date.now() - root.tmark > 1800, () => {
            root.check("c17: a recording mirror is not restarted for a new size (a restart would cut the file in two): no new session, no Resizing hold",
                       root.castStarts().length === root.cStarts + 1 && root.castHolds.indexOf("Resizing") < 0 && root.svcC.castPhase === "live", root.j(root.castHolds) + " starts " + root.castStarts().length);
            root.svcC.castStop();
            root.tmark = Date.now();
        });
        // (a toast that never comes is c18's failure, not a step's timeout)
        root.step("k: record told", () => root.posts.some(p => /^rec-/.test(p.key)) || Date.now() - root.tmark > 3000, () => {
            const rp = root.posts.filter(p => /^rec-/.test(p.key));
            root.check("c18: the recording's end is one toast saying where the file went",
                       rp.length === 1 && rp[0].title === "Recording saved" && rp[0].body === "/rec/phone-20261123-101010.mp4", root.j(rp));
            castPlan.setText(JSON.stringify({ from: 9999, mode: "ended", record: "error" }));
            root.resetToasts();
            root.cBefore = root.endedOf("c", "castprep").length;
            root.cStarts = root.castStarts().length;
            root.svcC.castStart(root.rm, "mirror", true);
        }, 5000);
        root.step("k: record live 2", () => root.svcC.castPhase === "live" && root.castStarts().length === root.cStarts + 1, () => {
            root.svcC.castStart(root.rm, "mirror", false);
            root.tmark = Date.now();
        });
        root.step("k: record switched off", () => (root.posts.some(p => /^rec-/.test(p.key)) || Date.now() - root.tmark > 4000) && root.svcC.castPhase === "live"
                  && root.castStarts().length === root.cStarts + 2, () => {
            const rp = root.posts.filter(p => /^rec-/.test(p.key)), cp = root.endedOf("c", "castprep"), st = root.castStarts();
            root.check("c19: Start with Record turned off over a recording cast ends the recording (its toast names the part kept when the file could not be finished) and casts on without one",
                       rp.length === 1 && /^Could not save the recording/.test(rp[0].title) && /boom: no muxer/.test(rp[0].body) && /kept in \/rec\/phone-20261123-101010\.mp4\.part\.flv/.test(rp[0].body)
                       && root.j(cp[cp.length - 1]) === root.j(["castprep", root.rm, "--unlock", "--hold"]) && st[st.length - 1].argv.indexOf("--record") < 0 && root.svcC.castRecording === false,
                       root.j(rp) + " " + root.j(cp[cp.length - 1]));
            root.svcC.castStop();
            castPlan.setText(JSON.stringify({ from: 9999, mode: "ended" }));
        }, 12000);

        // ===== a live service whose tool is not there ===========================================================================
        root.step("t: missing tool", () => true, () => {
            root.svcT = svcComp.createObject(root, { live: true, toolPath: w + "/none/lares-bridge", configPath: w + "/e/none.jsonc" });
            root.svcT.acted.connect((k, a, ok, why) => root.actedT.push([k, a, ok, why]));
            root.svcT.ring("kdc:x");
        });
        root.step("t: answered", () => root.actedT.length === 1, () => {
            root.check("t: a missing tool is a stated failure, and starts no process", root.j(root.actedT[0]) === root.j(["kdc:x", "ring", false, "the tool is missing"]) && root.svcT.ready === false
                       && root.svcT.picking === false, root.j(root.actedT));
        });

        // ===== (g) the config ====================================================================================================
        root.step("g: configs", () => true, () => {
            root.cfgMissing = cfgComp.createObject(root, { configPath: w + "/cfg/none.jsonc" });
            root.cfgBad = cfgComp.createObject(root, { configPath: w + "/cfg/bad.jsonc" });
            root.cfgBroken = cfgComp.createObject(root, { configPath: w + "/cfg/broken.jsonc" });
        });
        root.step("g: read", () => root.cfgBad.serial > 0 && root.cfgMissing.serial > 0 && root.cfgBroken.lastError !== "", () => {
            const cfgMissing = root.cfgMissing, cfgBad = root.cfgBad, cfgBroken = root.cfgBroken;
            const m = cfgMissing.settings, b = cfgBad.settings;
            root.check("g: a missing file gives the defaults", cfgMissing.present === false && cfgMissing.lastError === "" && m.files.usbMount === "/mnt/android" && m.mirror.wifi.maxSize === 1600
                       && m.mirror.wifi.bitRate === "6M" && m.mirror.wifi.maxFps === 60 && m.adb.start === "onDemand" && m.adb.port === 5555 && m.shots.dir === "~/Pictures/Screenshots"
                       && m.flip.onOpen === true && m.relight === true && m.files.open[0] === "kitty" && m.files.open.indexOf("{path}") > 0, root.j(m));
            root.check("g: a bad value clamps or takes its default, comments allowed", cfgBad.present && b.mirror.wifi.maxSize === 0 && b.mirror.wifi.bitRate === "6M" && b.mirror.wifi.maxFps === 240
                       && b.mirror.usb.maxSize === 16384 && b.adb.start === "onDemand" && b.adb.port === 65535 && b.adb.idleKillS === 0 && b.files.open[0] === "kitty" && b.files.usbMount === "/mnt/phone"
                       && b.relight === true && b.devices["Pixel 6 Pro"].hidden === true && b.devices.x.skin === "", root.j(b));
            root.check("g: a file that does not parse keeps the defaults and names its line", cfgBroken.settings.files.usbMount === "/mnt/android" && /line \d+/.test(cfgBroken.lastError), cfgBroken.lastError);
            root.check("g: the service reads the same config", root.svcL.settings.files.open[0] === "echo" && root.svcL.settings.mirror.wifi.maxSize === 1600);
            const own = list => Model.openArgv(Model.parseConfig({ files: { open: list } }).files.open, "/mnt/android");
            root.check("g: files.open with no \"{path}\" of its own is kept and given the path at its end, and {path} inside an element is filled in (the tool's rule)",
                       root.j(own(["thunar"])) === root.j(["thunar", "/mnt/android"]) && root.j(own(["sh", "-c", "yazi '{path}'"])) === root.j(["sh", "-c", "yazi '/mnt/android'"]),
                       root.j(own(["thunar"])) + " " + root.j(own(["sh", "-c", "yazi '{path}'"])));
            brokenFile.setText("{ \"files\": { \"usbMount\": \"/mnt/fixed\" } }\n");
        });
        root.step("g: hot", () => root.cfgBroken.settings.files.usbMount === "/mnt/fixed" && root.cfgBroken.lastError === "", () => {
            root.check("g: a fixed file is read hot, and the error goes", true);
        });
    }
    Component { id: cfgComp; BridgeConfig { live: true } }

    // ---- the cast: the service on a stub lares-bridge (castprep, unlock, usbcalm) and a stub lares-cast (the runner puts it in the copy
    // of tools/bridge/): it logs its argv and every command on stdin to c/cast.log, and prints what this harness appends to c/cast.out
    property var svcC: null
    property var castPhases: []
    property var castHolds: []
    Connections {
        target: root.svcC
        ignoreUnknownSignals: true
        function onCastPhaseChanged() { root.castPhases.push(root.svcC.castPhase); }
        function onCastHoldWhyChanged() { root.castHolds.push(root.svcC.castHoldWhy); }
    }
    FileView { id: castLogView; blockLoading: true; blockAllReads: true; printErrors: false; watchChanges: false }
    function castLog() {
        castLogView.path = "";
        castLogView.path = root.work + "/c/cast.log";
        castLogView.reload();
        return castLogView.text().trim().split("\n").filter(l => l !== "").map(l => JSON.parse(l));
    }
    function castStarts() { return root.castLog().filter(e => e.ev === "start"); }
    function castIns() { return root.castLog().filter(e => e.ev === "in").map(e => e.line); }
    FileView { id: castPlan; path: root.work + "/c/cast_plan.json"; blockWrites: true; printErrors: false; watchChanges: false }
    FileView { id: castAnswers; path: root.work + "/c/answers.json"; blockWrites: true; printErrors: false; watchChanges: false }
    function castDev(serial, mod) {
        return root.lineOf(serial, x => {
            x.devices = [x.devices[0]];
            const d = x.devices[0];
            d.pin = "set";
            d.can.unlock = { ok: true, why: "", hint: "", via: "usb" };
            d.facts = { model: "NX789J", android: "15", storageTotal: 100, storageFree: 50, batteryHealth: "Good", batteryTempC: 30, usbUnlocked: "none", at: 1 };
            if (mod)
                mod(d);
        });
    }
    property int cBefore: 0
    property bool cRecToast: false
    property int cUnl: 0
    property int cEnd: 0
    property int cStarts: 0
    property int cMark: 0
    property double cT0: 0
    property int cUsb: 0
    property var cfgMissing: null
    property var cfgBad: null
    property var cfgBroken: null
    property double tmark: 0
    FileView { id: brokenFile; path: root.work + "/cfg/broken.jsonc"; blockWrites: true; printErrors: false; watchChanges: false }
    property int factsBefore: 0

    function finish() {
        console.log("BRIDGE_SERVICE RESULT " + (root.fails.length === 0 && root.checks > 0 ? "PASS" : "FAIL") + " (" + root.checks + " checks"
                    + (root.fails.length ? "; failed: " + root.fails.join(", ") : "") + ")");
        quit.start();
    }
    Timer { id: quit; interval: 50; onTriggered: Qt.quit() }
    Timer { running: root.work !== ""; interval: 100; onTriggered: tick.start() }
}
